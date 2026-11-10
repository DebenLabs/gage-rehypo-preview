// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IRehypoExitDesk, IRehypoVault, IRehypoVaultFactory} from "../interfaces/rehypo/IRehypoVault.sol";
import {IRehypoPriceSource, IStockTokenMultiplier} from "../interfaces/rehypo/IRehypoPriceSource.sol";
import {IIntentFactoryRegistry} from "../interfaces/IIntentFactoryRegistry.sol";

/// @notice What a rehypo source fixes at creation beyond its float target (the next generation, 8 November 2026).
/// @param rangeTicks The narrowest just-in-time range the partner's hook commits to, in ticks (upper less lower), fixed
///        on the source's anchor between keeper moves (docs/rehypo-source.md, item 6); zero for the full range.
/// @param priceSource The Nuntius price source a priced source centres its band on; zero for a stable source.
/// @param pricedToken The pool token that price source values in USDG, the pool's other token being USDG; zero for a
///        stable source.
/// @param bandBps A priced source's band either side of its centre, in basis points of the price; zero when stable.
/// @param centreMoveBps How far a priced source's centre may move in an hour, in basis points of the price; zero when
///        stable.
struct RehypoSourceSettings {
    uint24 rangeTicks;
    address priceSource;
    address pricedToken;
    uint16 bandBps;
    uint16 centreMoveBps;
}

/// @title GageRehypoSource
/// @notice The ERC-4626 yield source a DEX's rehypothecation hook plugs into, one per pool and token: it holds a
/// float for swaps and lends the rest through a gage partner vault. A hook built on OpenZeppelin's `ReHypothecationHook`
/// with ERC-4626 sources (uniswap-hooks' `ReHypothecationERC4626Mock`: `deposit`, `withdraw`, `convertToAssets` of its
/// shares, swaps sized by `maxWithdraw`) uses it unchanged.
/// @dev The float is held as the PoolManager's ERC-6909 claims on the asset, so its tokens never leave the PoolManager:
/// the reserve a hook draws on when it takes a swap's input before the swapper pays stays there, and a v4 flash borrower
/// still finds it. The PoolManager's lock tells the two kinds of call apart. Inside an unlock (a swap's just-in-time
/// liquidity and its settlement) only the float moves, by minting and burning claims in that same unlock: deposits are
/// never refused, withdrawals are capped by the swap float, and the vault is never called, not even read, so a swap
/// cannot meet a vault refusal and pays no vault gas. Anyone can open an unlock, so a withdrawal inside one must settle
/// a debt the depositor already owes the PoolManager in the asset, as a swap's settlement does: an LP exit from an
/// unlock it opened itself cannot leave at the price that unlock reads or past a settlement. A deposit inside an
/// unlock looks the same as a swap's input, so the depositor must refuse LP entries while the PoolManager is unlocked
/// (docs/rehypo-source.md): otherwise an entry buys at the vault value of the last call outside an unlock and deepens
/// swaps by its whole amount. Outside an unlock (the hook's LP entries and exits, the keeper) the source follows the
/// vault: an exit may take the float and the vault's free cash, the vault paying first what the float cannot spare
/// above the swap float's share of what stays, so an exit narrows swaps only by what the vault cannot pay; entries and
/// exits wait while the vault settles a finished loan (`earliestMaturity`), so no LP moves at a price a pending
/// write-off is about to lower. The swap float follows each swap exactly, scales with the backing on entries and
/// exits, and resets to the float, never above its target, at each keeper rebalance (past the keeper's price band, at
/// most 1% of the target), so an LP's entry deepens swaps only by its share (as in the lender-AMM kit). One
/// depositor, bound once; shares never transfer, so the depositor holds every share and no price rounding moves value
/// between holders. sGAGE and recovered collateral go to the beneficiary; pockets paid in the asset join the float over
/// `RELEASE`. An LP whose share is more than the source can pay now exits through the chain's exit desk (`exitNow`):
/// the source commits its vault shares for the difference, a sale redeems them, and what the desk owes the
/// source counts in its backing and pays LP exits first.
///The next generation fixes three settings at creation, none of
/// which ever changes. A float-only source rebalances too: no vault moves, only the swap float. `RANGE_TICKS` is the
/// narrowest just-in-time range the partner's hook commits to, fixed on the source's anchor (parity on a stable source,
/// `centre` on a priced one) between keeper moves: zero, the full range, keeps the 28 October rule, where
/// the other side's capped float bounds a trade back past the band; a narrower range concentrates whatever float it
/// meets, so such a source caps its swap float on both sides of the band edge. Past the band it caps it whatever it
/// was, at the full-range cap times the range's concentration. Inside the band it opens swaps to at most the depth at
/// which a trade back from the band's edge to its centre takes under a thirty-second of the edge depth in one round,
/// and a sixteenth over any run of keeper passes (`_inBandCap`), whatever the range's width and the band's: the
/// backstop while the price drifts inside the band, and within the full range's bounds for a fair price anywhere in
/// it. A range that follows the price is not supported: each keeper pass would reopen the cap at the pushed price. A source is stable or priced: a stable source rebalances with the keeper's band,
/// at most `MAX_STABLE_BAND_TICKS` wide, and reads no price; a priced one, on an X/USDG pool, centres its band on a
/// Nuntius signed price (`rebalanceAt`), each report newer than the last, the centre moving at most `CENTRE_MOVE_BPS`
/// an hour. The price is read only there, outside every unlock: swaps, LP moves, exits and the vault never read it.
///A priced source may also be pegged (`PEG_BPS`, fixed at creation): a dollar stable against USDG (frxUSD/USDG,
/// eUSD/USDG) that follows its signed market price rather than parity. A keeper move then needs the signed price within
/// `PEG_BPS` of one USDG: further off, or stale, `rebalanceAt` reverts and nothing moves (no refill, no sweep, no
/// centre, no reopen) until the price is back inside, so the vault's cash never follows a coin off its peg into the
/// pool. Inside the band a pegged source opens swaps to its whole float, as the full range does, rather than to
/// `_inBandCap`: its centre is the signed price, never more than `PEG_BPS` from a dollar and moving at most
/// `CENTRE_MOVE_BPS` an hour, so the band sits on the market rather than on a parity the market may rest away from.
/// Past the band it caps the swap float as any declared range does.
contract GageRehypoSource is ERC4626, Ownable2Step, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint16 public constant BPS = 10_000;
    /// @notice The bounds of the float target, in basis points of the backing (float plus the vault shares' value).
    uint16 public constant MIN_FLOAT_BPS = 100;
    uint16 public constant MAX_FLOAT_BPS = 10_000;
    /// @notice Past the keeper's price band, a rebalance opens swaps to at most this share of the float target, or leaves
    /// the swap float where it was if that is more. A price pushed past the band meets a thin float, so trading it back
    /// pays less than the push cost; once traders bring the price back inside the band, the next rebalance opens swaps
    /// in full.
    uint16 public constant PAST_BAND_BPS = 100;
    /// @notice The notice a vault attached to a float-only source gives its depositor's LPs.
    uint32 public constant ATTACH_DELAY = 3 days;
    /// @notice The wait before a lower float target applies: lending more of the LPs' tokens loosens their exits, so it
    /// waits as a partner vault's "Cash kept free" does when lowered.
    uint32 public constant FLOAT_DELAY = 3 hours;
    /// @notice The time pocket proceeds paid in the asset take to join the float and the share price. Anyone may claim a
    /// pocket and its amount is public: joining at once, it would go to whoever held the depositor's LP shares in the
    /// claim's second, a flash entrant included.
    uint32 public constant RELEASE = 1 days;
    /// @notice How long an LP exit holds what its sales pay for the LPs who asked: until then only an LP's withdrawal
    /// takes it and no rebalance sweeps it back into the vault; after it anyone may end the exit (`endExit`).
    uint32 public constant EXIT_HOLD = 1 hours;
    /// @notice The narrowest range a partner may declare, in ticks: any range a pool can hold. Inside the band and past
    /// it, a declared range's swap float is capped by its width, so the narrower the range, the less of the float it
    /// meets (design decision 6).
    uint24 public constant MIN_RANGE_TICKS = 1;
    /// @notice The widest band a stable source's keeper may give, in ticks between its edges as `_bandTicks` counts
    /// them: about +-1% around the price.
    /// Inside the band a full-range source opens swaps in full and the failsafe may draw.
    uint24 public constant MAX_STABLE_BAND_TICKS = 200;
    /// @notice The widest declared range: the whole tick range.
    uint24 public constant MAX_RANGE_TICKS = 1_774_544;
    /// @notice Past the band, a source declared `RANGE_TICKS` wide caps its swap float at the full-range cap times
    /// `RANGE_TICKS / (RANGE_TICKS + CONCENTRATION_TICKS)`: no more than one over the most a range that wide concentrates
    /// two sides at its centre, `1 / (1 - 1.0001^(-w/4)) <= 1 + 4 / (w ln 1.0001)`, `4 / ln 1.0001` rounded up. Its
    /// liquidity past the band is then no deeper than the full range's.
    uint24 public constant CONCENTRATION_TICKS = 40_003;
    /// @notice The bounds of a priced source's band, either side of its centre.
    uint16 public constant MIN_BAND_BPS = 10;
    uint16 public constant MAX_BAND_BPS = 300;
    /// @notice The fastest a priced source's centre may be set to move, per hour.
    uint16 public constant MAX_CENTRE_MOVE_BPS = 1000;
    /// @notice How long a priced source moves nothing after its Stock Token's multiplier changes.
    uint32 public constant MULTIPLIER_HOLD = 1 hours;
    /// @notice The most a source may be set to draw from its vault between two keeper moves (`drawOnVault`), in basis
    /// points of its backing at the last move. Provisional (design decision 8).
    uint16 public constant MAX_FAILSAFE_BPS = 1000;
    /// @notice The widest peg a pegged source may hold its signed price to, either side of a dollar: 1%. The narrowest
    /// is `MIN_BAND_BPS`.
    uint16 internal constant MAX_PEG_BPS = 100;
    /// @dev One in sqrt-price units.
    uint256 internal constant Q96 = 1 << 96;

    /// @notice The Uniswap v4 PoolManager that holds the float as claims and whose lock separates swaps from the rest.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Intent factories whose vaults this source may lend through: the generation deployer's record.
    /// A vault is accepted only if a recorded factory created it.
    IIntentFactoryRegistry public immutable REGISTRY;
    /// @notice The smallest sweep into the vault: one whole unit of the asset, the vault's minimum deposit.
    uint256 public immutable MIN_SWEEP;
    /// @dev The asset as a v4 currency, and its ERC-6909 claim id.
    Currency internal immutable CURRENCY;
    uint256 internal immutable CLAIM_ID;
    /// @notice The narrowest just-in-time range the depositor's hook commits to, in ticks; zero for the full range.
    uint24 public immutable RANGE_TICKS;
    /// @notice A priced source's Nuntius price source; zero for a stable source.
    IRehypoPriceSource public immutable PRICE_SOURCE;
    /// @notice The pool token a priced source's price is of; zero for a stable source.
    address public immutable PRICED_TOKEN;
    /// @notice The price source's USDG, the pool's other token; zero for a stable source.
    address public immutable QUOTE;
    /// @notice A priced source's band either side of its centre, in basis points of the price.
    uint16 public immutable BAND_BPS;
    /// @notice How far a priced source's centre may move in an hour, in basis points of the price.
    uint16 public immutable CENTRE_MOVE_BPS;
    /// @notice The amount of `PRICED_TOKEN` a priced source values: a million whole tokens, so the value keeps its
    /// precision for a cheap token.
    uint256 public immutable PRICE_PROBE;
    /// @dev The band's edges as sqrt-price factors of the centre, in Q96.
    uint256 internal immutable BAND_LO_X96;
    uint256 internal immutable BAND_HI_X96;
    /// @notice The vault failsafe (2.5): the most `drawOnVault` takes from the vault between two keeper moves, in basis
    /// points of the backing at the last move; zero when off.
    uint16 public immutable FAILSAFE_BPS;
    /// @notice A pegged source's peg, in basis points of a dollar either side of one USDG: a keeper move takes a signed
    /// price only that close to it, and inside the band opens swaps to the whole float; zero when not pegged.
    uint16 public immutable PEG_BPS;
    /// @dev The peg as the price source's value of `PRICE_PROBE` (a million whole tokens at a dollar is a million whole
    /// USDG): the lowest and highest value a keeper move takes. Zero and the largest value when not pegged.
    uint256 internal immutable PEG_LO;
    uint256 internal immutable PEG_HI;

    /// @notice The gage partner vault lending the backing beyond the float; zero for a float-only source.
    IRehypoVault public vault;
    /// @notice The one account that deposits and withdraws: the hook, bound once.
    address public depositor;
    /// @notice The hook's pool, whose price decides how far a rebalance opens swaps.
    PoolId public poolId;
    /// @notice Where sGAGE and recovered collateral go: the partner's choice.
    address public beneficiary;
    /// @notice The float target, in basis points of the backing.
    uint16 public floatBps;
    /// @notice A lower float target the owner set, and when anyone may apply it; zero when none waits.
    uint16 public pendingFloatBps;
    uint40 public pendingFloatAt;
    /// @notice The most a swap may take from the float now.
    uint256 public swapFloat;
    /// @notice A vault proposed for a float-only source, and when it may be attached.
    IRehypoVault public pendingVault;
    uint40 public pendingVaultAt;
    /// @notice The accounts that may rebalance.
    mapping(address keeper => bool allowed) public isKeeper;
    /// @notice The chain's exit desk this source's LP exits go through, named by its vault's factory at the first exit
    /// and bound there for good; zero before any exit.
    IRehypoExitDesk public exitDesk;
    /// @notice Until when the last LP exit holds what its sales pay: no sweep and no `endExit` before then.
    uint40 public exitHeldUntil;
    /// @notice A priced source's band centre, as a v4 sqrt price, and when it was set; zero before its first
    /// `rebalanceAt`.
    uint160 public centre;
    uint40 public centreAt;
    /// @notice Until when a priced source moves nothing after its Stock Token's multiplier changed.
    uint40 public heldUntil;
    /// @notice The Stock Token multiplier a priced source last saw; zero before it saw one.
    uint256 public multiplier;
    /// @notice A failsafe source's band at its last rebalance, inside which `drawOnVault` may draw; zero before one.
    uint160 public bandLo;
    uint160 public bandHi;
    /// @notice The most the swap float may reach until the next keeper move, failsafe draws included: inside the band,
    /// a declared range's cap (`_inBandCap`), unlimited for the full range and a pegged source; zero past the band and
    /// before any move.
    uint256 public swapCap;
    /// @notice What `drawOnVault` may still draw until the next keeper move: `FAILSAFE_BPS` of the backing at the last
    /// move, at most what lifted the swap float to `swapCap` then, less the draws since; zero past the band, without the
    /// failsafe and before any move.
    uint256 public failsafeLeft;
    /// @notice When the Nuntius report a priced source last centred on was signed: each `rebalanceAt` needs a newer
    /// one, so no older report or replay moves the centre back; zero before the first.
    uint40 public reportAt;

    /// @dev The vault shares' value at the last call outside an unlock: what a swap prices shares on.
    uint256 internal _vaultAssets;
    /// @dev The vault shares this source bought itself, its backing. Shares anyone sends here are never valued: they
    /// would let a holder swap lent shares it cannot redeem for the LPs' float around an LP's entry and exit.
    uint256 internal _vaultShares;
    /// @dev Pocket proceeds still releasing: `_releasing` at `_releaseStart`, falling linearly to zero `RELEASE` later.
    /// They stay here as claims, held out of the float.
    uint216 internal _releasing;
    uint40 internal _releaseStart;
    /// @dev The vault shares committed at the exit desk as the desk last recorded them: what it has redeemed in sales
    /// since is how far its record has fallen below this.
    uint256 internal _committed;

    event Bound(address indexed depositor, PoolId indexed poolId);
    event KeeperSet(address indexed keeper, bool allowed);
    event FloatTargetSet(uint16 floatBps);
    event FloatTargetQueued(uint16 floatBps, uint40 readyAt);
    event BeneficiarySet(address indexed beneficiary);
    event VaultProposed(address indexed vault, uint40 readyAt);
    event VaultProposalCancelled(address indexed vault);
    event VaultAttached(address indexed vault);
    /// @notice One keeper move: what went into the vault, what came back, and the swap float it leaves.
    event Rebalanced(uint256 swept, uint256 refilled, uint256 swapFloat);
    /// @notice The band that keeper move used, as v4 sqrt prices, the most the swap float may reach until the next move
    /// (`swapCap`), and what the failsafe may draw until then (`failsafeLeft`).
    event BandSet(uint160 lo, uint160 hi, uint256 swapCap, uint256 failsafeLeft);
    /// @notice Pockets claimed, and the asset they paid, which joins the float over `RELEASE`.
    event PocketsClaimed(uint256[] pocketIds, uint256 proceeds);
    event RewardsClaimed(uint256 amount);
    event Forwarded(address indexed token, address indexed to, uint256 amount);
    /// @notice An LP asked to leave with `assets` more than the float and the exit desk's debt could pay; the source's
    /// whole commitment at the exit desk is now `shares` of its vault.
    event ExitRequested(address indexed lp, uint256 assets, uint256 shares);
    /// @notice A priced source's rebalance centred its band: the signed price as a v4 sqrt price, and the centre it set,
    /// the same unless the report moved further than `CENTRE_MOVE_BPS` allows.
    event Centred(uint160 reported, uint160 centre);
    /// @notice A priced source saw its Stock Token's multiplier change, and moves nothing until `heldUntil`.
    event MultiplierChanged(uint256 previous, uint256 current, uint40 heldUntil);
    /// @notice The failsafe drew `assets` from the vault into the float and the swap float, inside a swap's unlock; a
    /// source with no vault opened that much more of its float to swaps.
    event VaultDrawn(uint256 assets);

    error InvalidConfiguration();
    error InvalidFloatBps(uint16 floatBps);
    error NoPendingFloat();
    error FloatTooEarly(uint40 readyAt);
    error NotDepositor();
    error NotKeeper();
    error NotPoolManager();
    error AlreadyBound();
    error NotBound();
    /// @notice Called inside a PoolManager unlock, where the vault is never touched.
    error InsideUnlock();
    /// @notice A withdrawal inside an unlock that settles no debt of the depositor's: not a swap, so it waits for a call
    /// outside an unlock.
    error NotASwap();
    error NoVault();
    /// @notice No Intent factory the registry recorded created this vault: it is not a gage partner vault.
    error NotAGageVault();
    /// @notice The vault is between a loan's end and its settle: nothing moves through it until then.
    error VaultSettling();
    error VaultAlreadyAttached();
    error NoPendingVault();
    error AttachTooEarly(uint40 readyAt);
    /// @notice The asset and the vault's shares are backing: they leave only through the depositor's withdrawals.
    error ProtectedToken();
    error SharesNotTransferable();
    /// @notice The vault's factory names no exit desk: exits are closed, or the vault predates them.
    error NoExitDesk();
    /// @notice The caller's share of this source is no more than the source can pay now: it can leave as it is.
    error NothingToExit();
    /// @notice The last LP exit still holds what its sales pay.
    error ExitHeld(uint40 until);
    /// @notice `rebalance` takes the keeper's band, which a priced source never does: it centres on a signed price.
    error PricedSource();
    /// @notice `rebalanceAt` centres on a signed price, which a stable source never reads.
    error StableSource();
    /// @notice The Stock Token's multiplier changed less than `MULTIPLIER_HOLD` ago.
    error MultiplierHeld(uint40 until);
    /// @notice The price source valued the priced token at zero once its multiplier was applied.
    error NoPrice();
    /// @notice The source was created without the vault failsafe.
    error NoFailsafe();
    /// @notice Called outside a PoolManager unlock, where no swap is under way.
    error OutsideUnlock();
    /// @notice A band whose lower edge is above its upper one or outside v4's prices, or a stable band wider than
    /// `MAX_STABLE_BAND_TICKS`.
    error InvalidBand();
    /// @notice The report was signed no later than the one the centre last moved on.
    error StaleReport(uint256 observedAt, uint256 last);
    /// @notice A pegged source's signed price is further than `PEG_BPS` from a dollar: nothing moves until it is back.
    error OffPeg();

    /// @param asset_ The pool token this source holds.
    /// @param vault_ The gage partner vault of `asset_` that lends the backing beyond the float, or zero for a
    ///        float-only source (a vault can be attached later, after `ATTACH_DELAY`).
    /// @param poolManager The Uniswap v4 PoolManager of the depositor's pool.
    /// @param registry The generation deployer's record of the Intent factories whose vaults a source may lend through.
    /// @param owner_ The partner's Safe: it binds the depositor, names keepers and sets the float target.
    /// @param beneficiary_ Where sGAGE and recovered collateral go.
    /// @param floatBps_ The float target, `MIN_FLOAT_BPS` to `MAX_FLOAT_BPS`.
    /// @param settings The declared range and, for a priced source, its price source, priced token, band and centre
    ///        move, each within its bound; all zero for a stable full-range source.
    /// @param failsafeBps_ The vault failsafe's share of the backing per transaction, up to `MAX_FAILSAFE_BPS`; zero
    ///        for none.
    /// @param pegBps_ A priced source's peg to a dollar, `MIN_BAND_BPS` to `MAX_PEG_BPS`; zero when not pegged.
    /// @param name_ The share token's name.
    /// @param symbol_ The share token's symbol.
    constructor(
        IERC20 asset_,
        IRehypoVault vault_,
        IPoolManager poolManager,
        IIntentFactoryRegistry registry,
        address owner_,
        address beneficiary_,
        uint16 floatBps_,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps_,
        uint16 pegBps_,
        string memory name_,
        string memory symbol_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (
            address(asset_).code.length == 0 || address(poolManager).code.length == 0
                || address(registry).code.length == 0
        ) revert InvalidConfiguration();
        if (address(vault_) != address(0)) _requireGageVault(registry, vault_, address(asset_));
        POOL_MANAGER = poolManager;
        REGISTRY = registry;
        MIN_SWEEP = 10 ** IERC20Metadata(address(asset_)).decimals();
        CURRENCY = Currency.wrap(address(asset_));
        CLAIM_ID = uint256(uint160(address(asset_)));
        vault = vault_;
        _setBeneficiary(beneficiary_);
        _setFloatBps(floatBps_);
        uint24 range = settings.rangeTicks;
        if (range != 0 && (range < MIN_RANGE_TICKS || range > MAX_RANGE_TICKS)) revert InvalidConfiguration();
        RANGE_TICKS = range;
        if (failsafeBps_ > MAX_FAILSAFE_BPS) revert InvalidConfiguration();
        FAILSAFE_BPS = failsafeBps_;
        if (settings.priceSource == address(0)) {
            if (settings.pricedToken != address(0) || settings.bandBps != 0 || settings.centreMoveBps != 0) {
                revert InvalidConfiguration();
            }
        } else {
            QUOTE = _checkPriced(address(asset_), settings);
            PRICE_SOURCE = IRehypoPriceSource(settings.priceSource);
            PRICED_TOKEN = settings.pricedToken;
            BAND_BPS = settings.bandBps;
            CENTRE_MOVE_BPS = settings.centreMoveBps;
            PRICE_PROBE = 10 ** (uint256(IERC20Metadata(settings.pricedToken).decimals()) + 6);
            BAND_LO_X96 = Math.sqrt(Math.mulDiv(BPS - settings.bandBps, 1 << 192, BPS));
            BAND_HI_X96 = Math.sqrt(Math.mulDiv(BPS + settings.bandBps, 1 << 192, BPS));
        }
        PEG_BPS = pegBps_;
        if (pegBps_ == 0) {
            PEG_HI = type(uint256).max;
        } else {
            if (address(PRICE_SOURCE) == address(0) || pegBps_ < MIN_BAND_BPS || pegBps_ > MAX_PEG_BPS) {
                revert InvalidConfiguration();
            }
            // A million whole tokens at a dollar are a million whole USDG.
            uint256 par = 10 ** (uint256(IERC20Metadata(QUOTE).decimals()) + 6);
            PEG_LO = Math.mulDiv(par, BPS - pegBps_, BPS, Math.Rounding.Ceil);
            PEG_HI = Math.mulDiv(par, BPS + pegBps_, BPS);
        }
    }

    /// @dev A priced source's settings, at creation: an X/USDG pool, this source holding either side, its band and centre
    /// move in bounds. A declared range of any width fits any band: inside the band its swap float is capped by both
    /// (`_inBandCap`). Returns the price source's USDG.
    function _checkPriced(address asset_, RehypoSourceSettings memory s) private view returns (address quote) {
        quote = IRehypoPriceSource(s.priceSource).USDG();
        address priced = s.pricedToken;
        if (
            priced.code.length == 0 || priced == quote || (asset_ != priced && asset_ != quote)
                || s.bandBps < MIN_BAND_BPS || s.bandBps > MAX_BAND_BPS || s.centreMoveBps == 0
                || s.centreMoveBps > MAX_CENTRE_MOVE_BPS
        ) revert InvalidConfiguration();
    }

    // ---------------------------------------------------------------- ERC-4626

    /// @notice The float plus the vault shares at the vault's own price and what the exit desk owes this source. Inside
    /// an unlock the shares and the desk are valued at the last call outside one, so a swap never reads either; outside,
    /// live.
    function totalAssets() public view override returns (uint256) {
        return _float() + (POOL_MANAGER.isUnlocked() ? _vaultAssets : _lent());
    }

    /// @notice Unlimited for the depositor, inside an unlock always and outside it unless the vault is settling; zero for
    /// anyone else.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (receiver != depositor || receiver == address(0)) return 0;
        if (!POOL_MANAGER.isUnlocked() && _settling()) return 0;
        return type(uint256).max;
    }

    /// @notice As `maxDeposit`, in shares.
    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    /// @notice What the depositor can withdraw now: inside an unlock, the float up to the swap float; outside it, the
    /// float, what the exit desk owes this source and the vault's free cash, or nothing while the vault is settling. Zero
    /// for anyone else.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (owner != depositor || owner == address(0)) return 0;
        uint256 owned = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        if (POOL_MANAGER.isUnlocked()) return Math.min(owned, Math.min(_float(), swapFloat));
        if (_settling()) return 0;
        return Math.min(owned, _float() + _owed() + _vaultFree());
    }

    /// @notice As `maxWithdraw`, in shares, rounded down.
    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(balanceOf(owner), _convertToShares(maxWithdraw(owner), Math.Rounding.Floor));
    }

    /// @notice ERC-4626 deposit, by the depositor for itself.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @notice ERC-4626 mint, by the depositor for itself.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @notice ERC-4626 withdraw, by the depositor from its own shares.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice ERC-4626 redeem, by the depositor from its own shares.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice The asset this source holds for swaps and exits: its claims in the PoolManager and any tokens it holds
    /// itself (a refill not yet turned into claims, a donation), less the pocket proceeds still releasing.
    function float() external view returns (uint256) {
        return _float();
    }

    /// @notice The pocket proceeds still releasing: held here as claims, out of the float and the share price.
    function unreleased() public view returns (uint256) {
        uint256 end = uint256(_releaseStart) + RELEASE;
        if (block.timestamp >= end) return 0;
        return Math.mulDiv(_releasing, end - block.timestamp, RELEASE, Math.Rounding.Ceil);
    }

    // ---------------------------------------------------------------- keeper and claims

    /// @notice Move the float toward its target outside swaps: sweep the excess into the vault, at least one whole unit,
    /// or refill from the vault's free cash; a float-only source moves nothing and only sets its swap float. Resets the
    /// swap float to the float it leaves, never above the target, so an LP's entry still deepens swaps only by its share
    /// when the vault refuses the sweep. Sweeps nothing while an LP exit holds what its sales paid (`exitHeldUntil`).
    /// Keepers only, on a stable source, with a band at most `MAX_STABLE_BAND_TICKS` wide. While the pool's price is
    /// outside the keeper's band, the swap float rises to at most `PAST_BAND_BPS` of the target times the square of the
    /// price's ratio to the edge it is past (or stays where it was if that is more): OpenZeppelin's hook backs more
    /// depth with the same float the further the price is pushed, and the square holds what a trade back can take to
    /// about a sixteenth of the depth at the edge, on either side. A source declared narrower than the full range
    /// (`RANGE_TICKS`) caps it there whatever it was, at that cap scaled down by the range's concentration, and inside
    /// the band at `_inBandCap`. Sets what the failsafe may draw until the next move (`failsafeLeft`).
    /// @param minSqrtPriceX96 The lowest pool price, as a v4 sqrt price, at which the move opens swaps in full.
    /// @param maxSqrtPriceX96 The highest.
    function rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) external nonReentrant {
        _keeperMove(false);
        _checkBand(minSqrtPriceX96, maxSqrtPriceX96);
        if (_bandTicks(minSqrtPriceX96, maxSqrtPriceX96) > MAX_STABLE_BAND_TICKS) revert InvalidBand();
        _rebalance(minSqrtPriceX96, maxSqrtPriceX96);
    }

    /// @notice A priced source's rebalance: centre the band on the price a Nuntius report signs, moved from the last
    /// centre no further than `CENTRE_MOVE_BPS` an hour allows (the first report sets it), then move the float and set
    /// the swap float as `rebalance` does with `BAND_BPS` either side of that centre. A Stock Token's value takes its
    /// `uiMultiplier()`: the first call to see the multiplier change records it and moves nothing, and none moves for
    /// `MULTIPLIER_HOLD` after. Reverts whatever the price source refuses (a stale report, too few sources, an unnamed
    /// signer, a token under a corporate action), a report signed no later than the last one it centred on, a price
    /// no v4 pool can hold, and on a pegged source a price further than `PEG_BPS` from a dollar (`OffPeg`), leaving
    /// swaps as they are. Keepers only, outside an unlock.
    /// @param report An ABI-encoded Nuntius signed price for `PRICED_TOKEN`, as `NuntiusPriceSource.valueOf` takes it.
    function rebalanceAt(bytes calldata report) external nonReentrant {
        _keeperMove(true);
        if (block.timestamp < heldUntil) revert MultiplierHeld(heldUntil);
        address priced = PRICED_TOKEN;
        (,,,, bool stock) = PRICE_SOURCE.assetOf(priced);
        uint256 m;
        if (stock) {
            m = IStockTokenMultiplier(priced).uiMultiplier();
            uint256 last = multiplier;
            if (m != last) {
                multiplier = m;
                if (last != 0) {
                    uint40 until = uint40(block.timestamp) + MULTIPLIER_HOLD;
                    heldUntil = until;
                    emit MultiplierChanged(last, m, until);
                    return;
                }
            }
        }
        (uint256 value, uint256 observedAt) = PRICE_SOURCE.valueOf(priced, PRICE_PROBE, report);
        if (observedAt <= reportAt) revert StaleReport(observedAt, reportAt);
        reportAt = SafeCast.toUint40(observedAt);
        if (stock) value = Math.mulDiv(value, m, 1e18);
        if (value == 0) revert NoPrice();
        if (value < PEG_LO || value > PEG_HI) revert OffPeg();
        // The pool's price is token1 per token0 in raw units: USDG per priced token when that sorts first.
        uint256 reported = priced < QUOTE ? _sqrtPriceOf(value, PRICE_PROBE) : _sqrtPriceOf(PRICE_PROBE, value);
        uint256 next = reported;
        uint256 previous = centre;
        if (previous != 0) {
            // The price may move by `CENTRE_MOVE_BPS` for each hour since the last centre, either way: a sqrt factor.
            uint256 hour = uint256(BPS) * 1 hours;
            uint256 f =
                Math.sqrt(Math.mulDiv(hour + uint256(CENTRE_MOVE_BPS) * (block.timestamp - centreAt), 1 << 192, hour));
            next = Math.min(Math.max(reported, Math.mulDiv(previous, Q96, f)), Math.mulDiv(previous, f, Q96));
        }
        centre = uint160(next);
        centreAt = uint40(block.timestamp);
        emit Centred(uint160(reported), uint160(next));
        uint256 lo = Math.mulDiv(next, BAND_LO_X96, Q96);
        uint256 hi = Math.mulDiv(next, BAND_HI_X96, Q96);
        if (hi >= TickMath.MAX_SQRT_PRICE) revert InvalidBand();
        _checkBand(uint160(lo), uint160(hi));
        _rebalance(uint160(lo), uint160(hi));
    }

    /// @dev `num / den` as a v4 sqrt price: its square root in Q96. A ratio of 2^64 or more is rooted at 2^128, losing
    /// 32 of the root's low bits, so it never overflows; a price no v4 pool can hold reverts.
    function _sqrtPriceOf(uint256 num, uint256 den) internal pure returns (uint256 s) {
        uint256 ratio = num / den;
        if (ratio >= 1 << 128) revert NoPrice();
        uint256 shift = ratio < 1 << 64 ? 192 : 128;
        s = Math.sqrt(Math.mulDiv(num, 1 << shift, den)) << ((192 - shift) / 2);
        if (s < TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE) revert NoPrice();
    }

    /// @dev A band v4 can price: its lower edge at or above v4's lowest sqrt price, its upper edge below the highest and
    /// not below the lower.
    function _checkBand(uint160 lo, uint160 hi) internal pure {
        if (lo < TickMath.MIN_SQRT_PRICE || hi >= TickMath.MAX_SQRT_PRICE || lo > hi) revert InvalidBand();
    }

    /// @dev A checked band's width in ticks, never less than the ticks between its edges plus one: `2 ln(hi / lo) /
    /// ln(1.0001)`, bounded above through `ln(1 + x) <= x` by `(hi - lo) / lo * 20,001`, rounded down, plus one. At the
    /// widest bands a source takes (about 600 ticks) it counts about 1.5% more than there are.
    function _bandTicks(uint160 lo, uint160 hi) internal pure returns (uint256) {
        return Math.mulDiv(hi - lo, 20_001, lo) + 1;
    }

    /// @dev The preconditions of a keeper's move: outside an unlock, on a source of the kind the call serves, bound, by
    /// a keeper.
    function _keeperMove(bool priced) internal view {
        if (POOL_MANAGER.isUnlocked()) revert InsideUnlock();
        if ((PRICED_TOKEN != address(0)) != priced) {
            if (priced) revert StableSource();
            revert PricedSource();
        }
        if (depositor == address(0)) revert NotBound();
        if (!isKeeper[msg.sender]) revert NotKeeper();
    }

    /// @dev The move itself, with the band either kind of rebalance names.
    function _rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) internal {
        if (FAILSAFE_BPS != 0) (bandLo, bandHi) = (minSqrtPriceX96, maxSqrtPriceX96);
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        bool pastBand = sqrtPriceX96 < minSqrtPriceX96 || sqrtPriceX96 > maxSqrtPriceX96;
        if (_settling()) revert VaultSettling();
        IRehypoVault v = vault;
        uint256 held = _float();
        uint256 target = Math.mulDiv(held + _liveVaultAssets(), floatBps, BPS);
        uint256 swept;
        uint256 refilled;
        // A float-only source has nothing to sweep or refill.
        if (address(v) != address(0) && held > target) {
            swept = block.timestamp < exitHeldUntil ? 0 : Math.min(held - target, v.maxDeposit(address(this)));
            if (swept < MIN_SWEEP) {
                swept = 0;
            } else {
                // The desk's sales first: one that redeemed shares sent here beyond those this source bought must
                // not count against the shares it buys now.
                if (_committed != 0) _syncExit();
                _tokensInHand(swept);
                IERC20(asset()).forceApprove(address(v), swept);
                _vaultShares += v.deposit(swept, address(this));
                IERC20(asset()).forceApprove(address(v), 0);
            }
        } else if (address(v) != address(0) && held < target) {
            refilled = Math.min(target - held, _vaultFree());
            if (refilled != 0) _vaultShares -= v.withdraw(refilled, address(this), address(this));
        }
        _toClaims();
        // Never above the target: a sweep the vault refuses or caps leaves the float above it. Past the band, never
        // above `PAST_BAND_BPS` of the target, unless the swap float was already higher on a full-range source; a
        // narrower declared range scales that cap down and holds the swap float to it whatever it was. Inside the band
        // a declared range holds it to `_inBandCap`, which failsafe draws respect too, unless it is pegged: centred on
        // the market, it opens its whole float, as the full range does.
        uint256 depth = Math.min(_float(), target);
        uint256 range = RANGE_TICKS;
        uint256 ceiling;
        if (pastBand) {
            uint256 cap = _pastBandCap(target, sqrtPriceX96, minSqrtPriceX96, maxSqrtPriceX96);
            cap = range == 0 ? Math.max(cap, swapFloat) : Math.mulDiv(cap, range, range + CONCENTRATION_TICKS);
            depth = Math.min(depth, cap);
        } else {
            ceiling =
                range == 0 || PEG_BPS != 0 ? type(uint256).max : _inBandCap(target, minSqrtPriceX96, maxSqrtPriceX96);
            depth = Math.min(depth, ceiling);
        }
        swapFloat = depth;
        swapCap = ceiling;
        // The failsafe's room until the next move, from the backing now: no later deposit or donation inside a swap's
        // unlock raises it, and past the band there is none. Never more than lifts the swap float to the cap once, so
        // draws between two moves cannot refill what trades take.
        uint256 lent = _lent();
        uint256 room = pastBand ? 0 : Math.min(Math.mulDiv(_float() + lent, FAILSAFE_BPS, BPS), ceiling - depth);
        failsafeLeft = room;
        _vaultAssets = lent;
        emit Rebalanced(swept, refilled, depth);
        emit BandSet(minSqrtPriceX96, maxSqrtPriceX96, ceiling, room);
    }

    /// @dev Inside the band, the most a source declared `RANGE_TICKS` wide opens swaps to, for a band `w` ticks wide
    /// (`_bandTicks`, which never counts too few). A just-in-time range `r` ticks wide re-centred at each swap meets the swap
    /// float at a density of `2 / q` of it per tick, `q = r * C / (r + C)` with `C = CONCENTRATION_TICKS` (the full
    /// range's own density as `r` grows). A trade back from the band's edge to its centre, `w / 2` ticks, takes at most
    /// `min(1, w / q)` of the swap float at most `w / 2` ticks (about `w / 20,000` of the price) from its fair price.
    /// Holding that round under a thirty-second of the edge depth (`PAST_BAND_BPS` of the target) gives
    /// `target * PAST_BAND_BPS * max(w, q) / (16 w^2)`; holding a trade back in steps over any number of keeper passes,
    /// at most `(w / 2)^2 / q` ticks of the swap float in all, under a sixteenth gives `target * PAST_BAND_BPS * q /
    /// (5 w^2)`, the fifth also covering each pass's first step. With the fair price anywhere inside the band rather than
    /// at its centre a trade back runs up to `w` ticks, twice as far: the bounds become the full range's 1/16 and 1/4.
    /// The backstop for a range anchored between keeper moves (docs/rehypo-source.md, item 6) while the price drifts
    /// inside the band. At the +-0.5% band a +-0.5% range opens about 6% of the target (about 25 times the full range's
    /// depth at the price), a +-0.1% range about 4% and a +-0.05% range about 2%.
    function _inBandCap(uint256 target, uint160 lo, uint160 hi) internal view returns (uint256) {
        uint256 w = _bandTicks(lo, hi);
        uint256 rc = uint256(RANGE_TICKS) * CONCENTRATION_TICKS;
        uint256 rPlusC = uint256(RANGE_TICKS) + CONCENTRATION_TICKS;
        uint256 w2 = w * w;
        // max(w, q) = q exactly when r * C > w * (r + C).
        uint256 round = rc > w * rPlusC
            ? Math.mulDiv(target, uint256(PAST_BAND_BPS) * rc, 16 * w2 * rPlusC)
            : Math.mulDiv(target, PAST_BAND_BPS, 16 * w);
        uint256 stretch = Math.mulDiv(target, uint256(PAST_BAND_BPS) * rc, 5 * w2 * rPlusC);
        return Math.min(target, Math.min(round, stretch));
    }

    /// @dev `PAST_BAND_BPS` of the target times the square of the price's ratio to the band edge it is past: (s)^4 for
    /// the sqrt-price ratio s = price/min below the band or max/price above it, each step rounded down. The divisor is
    /// never zero: below the band the lower edge is above a price of at least zero, and above it the price is above an
    /// upper edge of at least v4's lowest sqrt price.
    function _pastBandCap(uint256 target, uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96)
        internal
        pure
        returns (uint256 cap)
    {
        cap = Math.mulDiv(target, PAST_BAND_BPS, BPS);
        (uint256 num, uint256 den) = sqrtPriceX96 < minSqrtPriceX96
            ? (uint256(sqrtPriceX96), uint256(minSqrtPriceX96))
            : (uint256(maxSqrtPriceX96), uint256(sqrtPriceX96));
        for (uint256 i; i < 4; ++i) {
            cap = Math.mulDiv(cap, num, den);
        }
    }

    /// @notice The vault failsafe (2.5), for the depositor inside a swap's unlock when the swap needs more than the
    /// float backs: draw up to `assets` of this source's own free cash at its vault into the float and the swap float,
    /// so the hook's next `maxWithdraw` includes it. Only while the price is inside the band of the last rebalance and
    /// that rebalance was inside it too, never above `swapCap`, and at most `failsafeLeft`: `FAILSAFE_BPS` of the
    /// backing at that rebalance, and no more than lifted the swap float to the cap then, for every transaction until
    /// the next one. A hook that never calls it, OpenZeppelin's
    /// unmodified one included, never touches the vault. A vault refusal undoes the draw and returns zero, and the swap
    /// goes on on the float; an empty revert (out of gas) reverts, so the gas a caller sends cannot choose the float
    /// over the vault. A source with no vault holds everything as float and opens only its float target to swaps: its
    /// draw opens more of the float it already holds, on the same rules and with nothing to move, so the cash a coin
    /// with no lend generation keeps free serves a swap as a vault's free cash does.
    /// @param assets The shortfall the hook needs beyond what the float backs.
    /// @return drawn What joined the swap float: zero past the band, with no room left, at the cap, without free cash
    /// (or, with no vault, float beyond the swap float), or on a refusal.
    function drawOnVault(uint256 assets) external nonReentrant returns (uint256 drawn) {
        if (FAILSAFE_BPS == 0) revert NoFailsafe();
        if (!POOL_MANAGER.isUnlocked()) revert OutsideUnlock();
        if (msg.sender != depositor) revert NotDepositor();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sqrtPriceX96 < bandLo || sqrtPriceX96 > bandHi) return 0;
        uint256 ceiling = swapCap;
        uint256 open = ceiling > swapFloat ? ceiling - swapFloat : 0;
        assets = Math.min(assets, Math.min(failsafeLeft, open));
        if (assets == 0) return 0;
        if (address(vault) == address(0)) {
            uint256 held = _float();
            drawn = Math.min(assets, held > swapFloat ? held - swapFloat : 0);
        } else {
            try this.drawFromVault(assets) returns (uint256 got) {
                drawn = got;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    assembly ("memory-safe") {
                        revert(add(reason, 32), mload(reason))
                    }
                }
                return 0;
            }
        }
        if (drawn == 0) return 0;
        failsafeLeft -= drawn;
        swapFloat += drawn;
        emit VaultDrawn(drawn);
    }

    /// @notice The vault part of `drawOnVault`, called by this source alone so that a refusal undoes all of it: withdraw
    /// up to `assets` of its own free cash, turn it into claims, and move it from the vault shares' snapshot to the
    /// float, so the backing and the share price stay where they were.
    /// @param assets The most to draw.
    /// @return got What was drawn.
    function drawFromVault(uint256 assets) external returns (uint256 got) {
        if (msg.sender != address(this)) revert NotDepositor();
        got = Math.min(assets, _vaultFree());
        if (got == 0) return 0;
        _vaultShares -= vault.withdraw(got, address(this), address(this));
        _mintClaims(got);
        uint256 snapshot = _vaultAssets;
        _vaultAssets = snapshot > got ? snapshot - got : 0;
    }

    /// @notice Claim this source's part of the vault's side pockets. What they pay in the asset (a repaid loan's
    /// earnings, a sale's gain, a write-off's backing) is held out of the float and joins it linearly over `RELEASE`, so
    /// the claim moves no price in its own second. Whatever was still releasing restarts with it: nothing joins faster
    /// than over `RELEASE` from its own claim. Recovered collateral waits here for `forward`. Anyone, outside an unlock.
    /// @param pocketIds The vault's pocket ids.
    function claimPockets(uint256[] calldata pocketIds) external nonReentrant {
        IRehypoVault v = _requireVaultOutsideUnlock();
        IERC20 token = IERC20(asset());
        uint256 held = token.balanceOf(address(this));
        v.claimPockets(pocketIds);
        uint256 proceeds = token.balanceOf(address(this)) - held;
        if (proceeds != 0) {
            _releasing = SafeCast.toUint216(unreleased() + proceeds);
            _releaseStart = uint40(block.timestamp);
        }
        _toClaims();
        _vaultAssets = _lent();
        emit PocketsClaimed(pocketIds, proceeds);
    }

    /// @notice Claim the sGAGE this source's vault shares have earned; `forward` sends it on. Anyone, outside an unlock.
    /// @return amount The sGAGE claimed.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        IRehypoVault v = _requireVaultOutsideUnlock();
        amount = v.claimRewards();
        emit RewardsClaimed(amount);
    }

    /// @notice Send this source's whole balance of `token`, anything but the asset and the vault's shares, to the
    /// beneficiary: sGAGE, recovered collateral, a token sent here by mistake. Anyone.
    /// @param token The token to send on.
    function forward(IERC20 token) external nonReentrant {
        if (address(token) == asset() || address(token) == address(vault) || address(token) == address(this)) {
            revert ProtectedToken();
        }
        uint256 amount = token.balanceOf(address(this));
        address to = beneficiary;
        token.safeTransfer(to, amount);
        emit Forwarded(address(token), to, amount);
    }

    // ---------------------------------------------------------------- exit now

    /// @notice Exit now, for an LP of the depositor whose share of this source is more than the source can pay now (the
    /// float, what the exit desk owes it and the vault's free cash): the source commits at the chain's exit desk the
    /// vault shares its float and the desk's debt cannot cover of that share, and the desk lists vault holding `id` for
    /// them, falling to book only for what the vault cannot pay. A sale redeems committed shares in its own transaction
    /// and the desk owes the source what they paid, which LP exits take before the vault's cash, so the LP then removes
    /// its liquidity as usual; what the sales pay is held for the LPs for `EXIT_HOLD`. The LP's share is read from the
    /// depositor's own LP token, and the commitment is the larger of the one still open and this LP's, never their sum:
    /// asking again, or with a second address, commits nothing more, and several LPs leave one after the other. Outside
    /// an unlock, while the vault is not settling and its factory names the desk.
    /// @param id The vault holding to list, as the desk lists exits; zero lists none, so a listing still live goes on,
    ///        or a filler lists the next.
    function exitNow(uint256 id) external nonReentrant {
        IRehypoVault v = _requireVaultOutsideUnlock();
        if (_settling()) revert VaultSettling();
        IRehypoExitDesk desk = IRehypoExitDesk(IRehypoVaultFactory(v.PROTOCOL_SOURCE()).exitDesk());
        if (address(desk) == address(0)) revert NoExitDesk();
        exitDesk = desk;
        _syncExit();
        // The depositor holds every share of this source; its LP token says what part of them the caller's is.
        IERC20 lp = IERC20(depositor);
        uint256 lpSupply = lp.totalSupply();
        uint256 claim = lpSupply == 0 ? 0 : Math.mulDiv(totalAssets(), lp.balanceOf(msg.sender), lpSupply);
        uint256 cash = _float() + _owed();
        if (claim <= cash + _vaultFree()) revert NothingToExit();
        uint256 shares = Math.min(Math.max(_committed, v.previewWithdraw(claim - cash)), _vaultShares);
        v.approve(address(desk), shares);
        desk.exitNow(address(v), shares, id);
        _committed = shares;
        exitHeldUntil = uint40(block.timestamp) + EXIT_HOLD;
        emit ExitRequested(msg.sender, claim - cash, shares);
    }

    /// @notice End the last LP exit once `EXIT_HOLD` has passed since it was asked: withdraw what is still committed at
    /// the desk, and bring what its sales paid into the float, from where the next rebalance lends it again. Anyone,
    /// outside an unlock.
    function endExit() external nonReentrant {
        IRehypoVault v = _requireVaultOutsideUnlock();
        IRehypoExitDesk desk = exitDesk;
        if (address(desk) == address(0)) revert NoExitDesk();
        if (block.timestamp < exitHeldUntil) revert ExitHeld(exitHeldUntil);
        _syncExit();
        if (_committed != 0) desk.cancel(address(v));
        _committed = 0;
        if (_owed() != 0) desk.withdraw(asset());
        _toClaims();
        _vaultAssets = _lent();
    }

    /// @notice The PoolManager's callback for this source's own unlocks, outside swaps: turn tokens into claims, or
    /// claims back into tokens.
    /// @dev The PoolManager calls back only the account that unlocked it, so only this source's own unlocks reach here.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (bool toClaims, uint256 amount) = abi.decode(data, (bool, uint256));
        if (toClaims) _mintClaims(amount);
        else _burnClaims(amount);
        return "";
    }

    // ---------------------------------------------------------------- owner

    /// @notice Bind the hook's pool, once: its hook becomes the one depositor. The pool must exist in the PoolManager and
    /// hold this source's asset, so a source can only ever serve the pool it was made for; a priced source's pool is its
    /// priced token against USDG.
    /// @param key The hook's pool, whose price decides how far a rebalance opens swaps.
    function bind(PoolKey calldata key) external onlyOwner {
        if (depositor != address(0)) revert AlreadyBound();
        address hook = address(key.hooks);
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        address priced = PRICED_TOKEN;
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (
            hook.code.length == 0 || hook == address(this) || sqrtPriceX96 == 0
                || !(key.currency0 == CURRENCY || key.currency1 == CURRENCY)
                || (priced != address(0) && !((c0 == priced && c1 == QUOTE) || (c0 == QUOTE && c1 == priced)))
        ) revert InvalidConfiguration();
        depositor = hook;
        poolId = id;
        emit Bound(hook, id);
    }

    /// @notice Allow or stop an account rebalancing.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert InvalidConfiguration();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Set the float target; the next rebalance moves toward it. A higher target (more kept for swaps and
    /// exits) applies at once and drops any lower one waiting; a lower target (more of the LPs' tokens lent) waits
    /// `FLOAT_DELAY`, then anyone applies it with `applyFloatBps`.
    /// @param floatBps_ The target, `MIN_FLOAT_BPS` to `MAX_FLOAT_BPS`.
    function setFloatBps(uint16 floatBps_) external onlyOwner {
        if (floatBps_ < MIN_FLOAT_BPS || floatBps_ > MAX_FLOAT_BPS) revert InvalidFloatBps(floatBps_);
        if (floatBps_ >= floatBps) {
            delete pendingFloatBps;
            delete pendingFloatAt;
            _setFloatBps(floatBps_);
            return;
        }
        uint40 readyAt = uint40(block.timestamp) + FLOAT_DELAY;
        pendingFloatBps = floatBps_;
        pendingFloatAt = readyAt;
        emit FloatTargetQueued(floatBps_, readyAt);
    }

    /// @notice Apply the lower float target the owner set `FLOAT_DELAY` ago. Anyone.
    function applyFloatBps() external {
        uint16 queued = pendingFloatBps;
        if (queued == 0) revert NoPendingFloat();
        if (block.timestamp < pendingFloatAt) revert FloatTooEarly(pendingFloatAt);
        delete pendingFloatBps;
        delete pendingFloatAt;
        _setFloatBps(queued);
    }

    /// @notice Set where sGAGE and recovered collateral go.
    function setBeneficiary(address beneficiary_) external onlyOwner {
        _setBeneficiary(beneficiary_);
    }

    /// @notice Propose a vault for a float-only source; it may be attached `ATTACH_DELAY` later, so the depositor's LPs
    /// see their tokens are about to be lent.
    /// @param vault_ A gage partner vault of this source's asset.
    function proposeVault(IRehypoVault vault_) external onlyOwner {
        if (address(vault) != address(0)) revert VaultAlreadyAttached();
        if (address(vault_) == address(0)) revert InvalidConfiguration();
        _requireGageVault(REGISTRY, vault_, asset());
        uint40 readyAt = uint40(block.timestamp) + ATTACH_DELAY;
        pendingVault = vault_;
        pendingVaultAt = readyAt;
        emit VaultProposed(address(vault_), readyAt);
    }

    /// @notice Drop the proposed vault.
    function cancelVault() external onlyOwner {
        IRehypoVault proposed = pendingVault;
        if (address(proposed) == address(0)) revert NoPendingVault();
        delete pendingVault;
        delete pendingVaultAt;
        emit VaultProposalCancelled(address(proposed));
    }

    /// @notice Attach the proposed vault once its notice has run; it is this source's vault for good.
    function attachVault() external onlyOwner {
        if (address(vault) != address(0)) revert VaultAlreadyAttached();
        IRehypoVault proposed = pendingVault;
        if (address(proposed) == address(0)) revert NoPendingVault();
        if (block.timestamp < pendingVaultAt) revert AttachTooEarly(pendingVaultAt);
        vault = proposed;
        delete pendingVault;
        delete pendingVaultAt;
        emit VaultAttached(address(proposed));
    }

    // ---------------------------------------------------------------- internals

    /// @dev Only the depositor, for itself (`maxDeposit` names it as the only receiver). The tokens become claims at
    /// once. Inside an unlock the deposit joins the swap float, up to the `swapCap` the last move set inside the band
    /// (no swap's input lifts a declared range past it until the next move). Outside it a full-range float-only source opens
    /// its whole float to swaps: all its backing is float, so a donation or a rounding remainder would otherwise narrow
    /// its swaps until its keeper's next pass. A lending source's swap float grows with the backing, the first deposit
    /// into a source with no shares setting it, whatever the source already holds; its keeper's rebalance resets it. So
    /// does a float-only source declared narrower than the full range: past the band its keeper holds its swap float to
    /// the scaled cap, which an LP's entry must not undo.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != depositor) revert NotDepositor();
        bool unlocked = POOL_MANAGER.isUnlocked();
        uint256 backing = unlocked ? 0 : totalAssets();
        bool first = totalSupply() == 0;
        super._deposit(caller, receiver, assets, shares);
        if (unlocked) {
            if (assets != 0) _mintClaims(assets);
            // A swap's input deepens swaps up to the cap of the last move inside the band, never past it.
            uint256 next = swapFloat + assets;
            uint256 cap = swapCap;
            swapFloat = cap == 0 || next <= cap ? next : Math.max(cap, swapFloat);
        } else {
            _toClaims();
            if (address(vault) == address(0) && RANGE_TICKS == 0) swapFloat = _float();
            else swapFloat = first || backing == 0 ? assets : Math.mulDiv(swapFloat, backing + assets, backing);
            _vaultAssets = _lent();
        }
    }

    /// @dev Only the depositor, from its own shares (`maxWithdraw` names it as the only owner). Inside an unlock only a
    /// swap's settlement withdraws: the depositor must already owe the PoolManager at least `assets` of the asset, a
    /// debt only its own calls can open, and the float pays it, the swap float falling by the same amount. Outside an
    /// unlock the vault's free cash pays what the float cannot spare above the swap float's share of the backing that
    /// stays, and the float pays the rest: the swap float keeps its share, or falls to the float left when the vault
    /// cannot pay its part. A vault refusal its maximum did not foresee (`RewardsPending`) leaves the vault's part to
    /// the float when the float can pay the whole exit; an empty revert (out of gas) never does. A refusal the vault
    /// makes of its own inner out-of-gas (IntentVault turns a failed reward claim into `RewardsPending`) rests on the
    /// 63/64 rule instead: the gas left must still finish the exit, so a caller would need that claim to cost millions
    /// of gas to pick the float. No exit deepens swaps, or takes more of the float than the float paying first did. A
    /// full-range float-only source's swap float is its float; one declared narrower keeps its share, as a lending
    /// source's does. What the exit desk owes this source, held for these exits, pays before the vault, collected whole
    /// once the float cannot spare the exit; an exit the float can pay leaves it there.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != depositor) revert NotDepositor();
        if (POOL_MANAGER.isUnlocked()) {
            int256 owed = POOL_MANAGER.currencyDelta(caller, CURRENCY);
            if (owed >= 0 || uint256(-owed) < assets) revert NotASwap();
            uint256 inHand = IERC20(asset()).balanceOf(address(this));
            if (assets > inHand) _burnClaims(assets - inHand);
            swapFloat -= assets;
            super._withdraw(caller, receiver, owner, assets, shares);
            return;
        }
        uint256 held = _float();
        uint256 owed = _owed();
        uint256 backing = held + owed + _liveVaultAssets();
        uint256 share = backing == 0 ? 0 : Math.mulDiv(Math.min(swapFloat, held), backing - assets, backing);
        if (owed != 0 && assets + share > held) {
            exitDesk.withdraw(asset());
            held += owed;
        }
        uint256 fromVault = assets + share > held ? Math.min(assets + share - held, _vaultFree()) : 0;
        if (fromVault != 0) {
            try vault.withdraw(fromVault, address(this), address(this)) returns (uint256 burned) {
                _vaultShares -= burned;
            } catch (bytes memory reason) {
                if (reason.length == 0 || assets > held) {
                    assembly ("memory-safe") {
                        revert(add(reason, 32), mload(reason))
                    }
                }
            }
        }
        _tokensInHand(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
        _toClaims();
        swapFloat = address(vault) == address(0) && RANGE_TICKS == 0 ? _float() : Math.min(share, _float());
        _vaultAssets = _lent();
    }

    /// @dev Virtual shares, OpenZeppelin's inflation defence. With one depositor they move no value between holders, but
    /// proceeds still releasing when every share has left stay as assets over no shares, and a deposit there must still
    /// mint what it pays for.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Shares only mint and burn: the depositor holds every one.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert SharesNotTransferable();
        super._update(from, to, value);
    }

    /// @dev Outside an unlock: hold at least `amount` of the asset as tokens, burning claims for the rest.
    function _tokensInHand(uint256 amount) internal {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (amount > held) POOL_MANAGER.unlock(abi.encode(false, amount - held));
    }

    /// @dev Outside an unlock: turn every token this source holds into claims.
    function _toClaims() internal {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (held != 0) POOL_MANAGER.unlock(abi.encode(true, held));
    }

    /// @dev Inside an unlock: pay `amount` of tokens to the PoolManager and take claims for it; this source's deltas net
    /// to zero.
    function _mintClaims(uint256 amount) internal {
        POOL_MANAGER.sync(CURRENCY);
        IERC20(asset()).safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle();
        POOL_MANAGER.mint(address(this), CLAIM_ID, amount);
    }

    /// @dev Inside an unlock: burn `amount` of claims and take the tokens; this source's deltas net to zero.
    function _burnClaims(uint256 amount) internal {
        POOL_MANAGER.burn(address(this), CLAIM_ID, amount);
        POOL_MANAGER.take(CURRENCY, address(this), amount);
    }

    /// @dev A gage partner vault of `asset_`: an Intent factory the registry recorded created it, and it is on that
    /// factory's own record.
    function _requireGageVault(IIntentFactoryRegistry registry, IRehypoVault v, address asset_) internal view {
        if (v.asset() != asset_) revert InvalidConfiguration();
        address factory = v.PROTOCOL_SOURCE();
        if (!registry.isFactory(factory) || !IRehypoVaultFactory(factory).isVault(address(v))) revert NotAGageVault();
    }

    function _requireVaultOutsideUnlock() internal view returns (IRehypoVault v) {
        if (POOL_MANAGER.isUnlocked()) revert InsideUnlock();
        v = vault;
        if (address(v) == address(0)) revert NoVault();
    }

    function _setFloatBps(uint16 floatBps_) internal {
        if (floatBps_ < MIN_FLOAT_BPS || floatBps_ > MAX_FLOAT_BPS) revert InvalidFloatBps(floatBps_);
        floatBps = floatBps_;
        emit FloatTargetSet(floatBps_);
    }

    function _setBeneficiary(address beneficiary_) internal {
        if (beneficiary_ == address(0) || beneficiary_ == address(this)) revert InvalidConfiguration();
        beneficiary = beneficiary_;
        emit BeneficiarySet(beneficiary_);
    }

    /// @dev The asset held for swaps and exits: claims in the PoolManager plus tokens held here, less the pocket proceeds
    /// still releasing. Every outflow (a swap's settlement, an exit's float part, a sweep) is capped by it, so the
    /// holding never falls below `unreleased()`, which rises only at a claim and by what the claim brought in; the floor
    /// at zero only keeps a swap from ever reverting here.
    function _float() internal view returns (uint256) {
        uint256 held = POOL_MANAGER.balanceOf(address(this), CLAIM_ID) + IERC20(asset()).balanceOf(address(this));
        uint256 releasing = unreleased();
        return held > releasing ? held - releasing : 0;
    }

    /// @dev The value of the vault shares this source bought itself and still holds, at the vault's live price; zero
    /// without a vault.
    function _liveVaultAssets() internal view returns (uint256) {
        IRehypoVault v = vault;
        if (address(v) == address(0)) return 0;
        return v.convertToAssets(_ownShares());
    }

    /// @dev The vault shares this source bought itself, less what the exit desk has redeemed from it in sales since the
    /// last commitment (the fall of the desk's record below `_committed`), never below zero.
    function _ownShares() internal view returns (uint256) {
        if (_committed == 0) return _vaultShares;
        uint256 redeemed = _committed - Math.min(_left(), _committed);
        return _vaultShares - Math.min(redeemed, _vaultShares);
    }

    /// @dev The shares the exit desk may still redeem from this source: its record of the commitment.
    function _left() internal view returns (uint256 left) {
        (left,,) = exitDesk.exits(address(vault), address(this));
    }

    /// @dev Before a commitment changes: drop what the desk redeemed since the last from this source's count of its
    /// shares, and take the desk's record as the commitment.
    function _syncExit() internal {
        _vaultShares = _ownShares();
        _committed = _left();
    }

    /// @dev What the exit desk owes this source from its exits' sales; zero before any exit.
    function _owed() internal view returns (uint256) {
        IRehypoExitDesk desk = exitDesk;
        return address(desk) == address(0) ? 0 : desk.owed(asset(), address(this));
    }

    /// @dev The vault shares' value and what the exit desk owes: the backing beyond the float.
    function _lent() internal view returns (uint256) {
        return _liveVaultAssets() + _owed();
    }

    /// @dev What the vault can pay this source now, never more than its own shares are worth; zero without a vault.
    function _vaultFree() internal view returns (uint256) {
        IRehypoVault v = vault;
        if (address(v) == address(0)) return 0;
        return Math.min(v.maxWithdraw(address(this)), _liveVaultAssets());
    }

    /// @dev Whether the vault is between a loan's end and its settle; never without a vault.
    function _settling() internal view returns (bool) {
        IRehypoVault v = vault;
        return address(v) != address(0) && block.timestamp >= v.earliestMaturity();
    }
}
