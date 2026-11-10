// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {UnlockCheckedHook} from "../src/UnlockCheckedHook.sol";
import {FailsafeUnlockCheckedHook} from "../src/FailsafeUnlockCheckedHook.sol";
import {AnchoredUnlockCheckedHook, AnchoredFailsafeUnlockCheckedHook} from "../src/AnchoredUnlockCheckedHook.sol";
import {AnchoredFeeHook, AnchoredFailsafeFeeHook} from "../src/AnchoredFeeHook.sol";

/// @notice What a source fixes at creation beyond its float target (`GageRehypoSourceSettings`, the next generation of
/// 8 November 2026): the narrowest range the hook commits to (zero for the full range) and, for a priced X/USDG pool,
/// its price source (the factory's), priced token, band and hourly centre move (all zero for a stable source).
struct RehypoSourceSettings {
    uint24 rangeTicks;
    address priceSource;
    address pricedToken;
    uint16 bandBps;
    uint16 centreMoveBps;
}

/// @notice gage's rehypo source factory (`src/rehypo/GageRehypoSourceFactory.sol`), as a partner calls it.
interface IGageRehypoSourceFactory {
    function POOL_MANAGER() external view returns (IPoolManager);
    function REGISTRY() external view returns (address);
    function PRICE_SOURCE() external view returns (address);
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external returns (address source);
    /// @dev The same with the vault failsafe (design 2.5): `failsafeBps` of the backing per transaction, 0 for none.
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external returns (address source);
    function predict(
        address creator,
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external view returns (address);
    function predict(
        address creator,
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external view returns (address);
    /// @dev The same with a peg (`PEG_BPS`): a priced source of a dollar stable against USDG, 0 for none.
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external returns (address source);
    function predict(
        address creator,
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external view returns (address);
}

/// @notice A rehypo source (`GageRehypoSource`), as its owner sets it up and the keeper rebalances it.
interface IGageRehypoSource {
    function asset() external view returns (address);
    function vault() external view returns (address);
    function depositor() external view returns (address);
    function isKeeper(address keeper) external view returns (bool);
    function floatBps() external view returns (uint16);
    function swapCap() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) external;
    function PRICED_TOKEN() external view returns (address);
    function FAILSAFE_BPS() external view returns (uint16);
    function RANGE_TICKS() external view returns (uint24);
    function PEG_BPS() external view returns (uint16);
}

/// @notice The generation deployer's record of the Intent factories whose vaults a source may lend through.
interface IIntentFactoryRegistry {
    function isFactory(address factory) external view returns (bool);
}

/// @notice The one read the script makes of a price source (a `RehypoPriceRouter`, or an earlier factory's Nuntius
/// source) before naming it to the factory.
interface IPriceSourceUsdg {
    function USDG() external view returns (address);
}

/// @notice gage's rehypo source in one script. `run` is the release step: it deploys the source factory with the
/// generation deployer as its registry (2b), right after the release deploys that deployer. `rehearse` sets a stable
/// pool up as `docs/rehypo-source.md` "Set-up" lists it, `rehearsePriced` an X/USDG pool whose sources centre their
/// band on a signed price, and `rehearsePegged` a dollar stable against USDG whose sources centre on its signed price
/// within a peg (`PEG_BPS`): the testnet rehearsals, and the reference handed to partners, whose Safe makes the same
/// calls in the same order. Guide: docs/rehypo-source.md, "Running it".
/// @dev The factory compiles in `contracts/` (0.8.28, the `rehypo` profile) and this kit with 0.8.26, so the script
/// deploys it from its artifact there: `forge build src/rehypo/GageRehypoSourceFactory.sol` in `contracts/` first.
contract RehypoSource is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAINNET = 4663;
    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    /// @dev `ReHypothecationHook`'s permissions, which the reference hook does not change.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev A stable pair's pool: 0.01%, every tick. A static fee, unless the pool takes a fee rule (`FeeRule`), when it
    /// is a dynamic-fee pool and the kit's fee hook names each swap's fee.
    uint24 internal constant FEE = 100;
    /// @dev A fee rule's bounds when the caller sets none: the kit's lowest floor, 0.01%, and a 1% cap.
    uint24 internal constant FEE_FLOOR = 100;
    uint24 internal constant FEE_CAP = 10_000;
    uint24 internal constant MAX_FEE_CAP = 50_000;
    int24 internal constant TICK_SPACING = 1;
    uint16 internal constant BPS = 10_000;
    /// @dev The float-only side keeps all its backing as float.
    uint16 internal constant ALL_FLOAT = 10_000;
    /// @dev The keeper's band: 0.5% either side of one whole unit for one whole unit.
    uint16 internal constant BAND_BPS = 50;
    /// @dev A priced source's defaults: 1% either side of the signed price, its centre moving at most 5% an hour.
    uint16 internal constant PRICED_BAND_BPS = 100;
    uint16 internal constant PRICED_MOVE_BPS = 500;
    /// @dev A pegged source's defaults: the keeper's usual 0.5% band either side of the signed price, its centre moving
    /// at most 1% an hour, its signed price within 0.5% of a dollar for a keeper move.
    uint16 internal constant PEGGED_BAND_BPS = 50;
    uint16 internal constant PEGGED_MOVE_BPS = 100;
    uint16 internal constant PEG_BPS = 50;
    /// @dev What a vault failsafe draw costs in gas, its own and the keeper's sweep back, in dollars with eight decimals
    /// (ten cents): the least fee a draw must earn (`FailsafeUnlockCheckedHook.MIN_DRAW_FEE_0` and `_1`).
    uint256 internal constant DRAW_COST_8 = 1e7;
    /// @dev The lending return a draw gives up until the keeper's next pass lends it again, in pips of the draw: about
    /// an hour at 9% a year (`FailsafeUnlockCheckedHook.FORGONE_PIPS`).
    uint24 internal constant FORGONE_PIPS = 10;
    /// @dev One whole lent unit for one whole float-only unit, in `price8` terms.
    uint256 internal constant ONE = 1e8;
    /// @dev The source's own bounds (`GageRehypoSource`), so an environment value outside them is refused here rather
    /// than cut to the setting's type: `MAX_RANGE_TICKS`, `MAX_FAILSAFE_BPS`, `MIN_FLOAT_BPS`, `MIN_BAND_BPS`,
    /// `MAX_BAND_BPS`, `MAX_CENTRE_MOVE_BPS` and `MAX_PEG_BPS` (the narrowest peg is `MIN_BAND_BPS`).
    uint256 internal constant MAX_RANGE_TICKS = 1_774_544;
    uint256 internal constant MAX_FAILSAFE_BPS = 1000;
    uint256 internal constant MIN_FLOAT_BPS = 100;
    uint256 internal constant MIN_BAND_BPS = 10;
    uint256 internal constant MAX_BAND_BPS = 300;
    uint256 internal constant MAX_CENTRE_MOVE_BPS = 1000;
    uint256 internal constant MAX_PEG_BPS = 100;
    /// @dev A declared stable pool's first deposit, before the first keeper move: this share of the seed (a hundredth).
    uint256 internal constant FIRST_SEED_SHARE = 100;
    /// @dev OpenZeppelin's smallest seed, in shares (`100 * 10 ** _decimalsOffset()`).
    uint256 internal constant MIN_SEED_SHARES = 1e8;

    /// @notice A pool's two sides: one lent through a gage vault, one float-only.
    struct Pool {
        IGageRehypoSourceFactory factory;
        /// @dev The lent side (USDG), its gage partner vault (from a factory the generation deployer recorded) and its
        /// float target. A pool whose sources declare a range gives the float-only side the same target: equal float
        /// targets, the rule a declared range takes (docs/rehypo-source.md, item 6).
        IERC20 lend;
        address vault;
        uint16 floatBps;
        /// @dev The float-only side (frxUSD on day one): all its backing as float on the full range, the lent side's
        /// target on a declared range.
        IERC20 floatOnly;
        address keeper;
        /// @dev The seed, in raw units of each token.
        uint256 seedLend;
        uint256 seedFloat;
        /// @dev The creator's CREATE2 salt for both sources; a second run from the same broadcaster needs another.
        bytes32 salt;
        /// @dev Both sources' settings: the declared range and, for a priced pool, the price settings.
        RehypoSourceSettings settings;
        /// @dev The pool's starting price: whole lent units for one whole float-only unit, eight decimals (`ONE` for a
        /// stable pair, the signed price for a priced one).
        uint256 price8;
        /// @dev The failsafe (design 2.5): the share of its backing a source may open to swaps between two keeper
        /// moves beyond its float, 0 for none. The lent source draws it from its vault's free cash; on a declared range
        /// the float-only source takes it too, from the float it keeps closed, and on the full range has none (its
        /// whole float is open). Non-zero, the pool's hook is `FailsafeUnlockCheckedHook` (or its anchored form), which
        /// asks for it.
        uint16 failsafeBps;
        /// @dev Both sources' peg (`PEG_BPS`) on a priced pool of a dollar stable against USDG: a keeper move takes a
        /// signed price within it of a dollar, and inside the band opens the whole float. 0 for none.
        uint16 pegBps;
    }

    /// @notice A pool's swap fee as a rule (the kit's fee hooks, `src/AnchoredFeeHook.sol`): each swap pays what `module`
    /// (a venue's fee contract, `IRehypoFeeSource`) quotes for its own pool `poolId`, held between `floor` and `cap`, in
    /// pips. A zero `module` is no rule: the pool keeps the static `FEE`. A rule needs both sources to declare a range.
    struct FeeRule {
        address module;
        PoolId poolId;
        uint24 floor;
        uint24 cap;
    }

    /// @notice What the set-up leaves: the two sources, the hook (a `FailsafeUnlockCheckedHook` when the lent source has
    /// the failsafe; its anchored form, `AnchoredUnlockCheckedHook` or `AnchoredFailsafeUnlockCheckedHook`, when both
    /// sources declare a range; `AnchoredFeeHook` or `AnchoredFailsafeFeeHook` with a fee rule) and its pool.
    struct Plugged {
        IGageRehypoSource lendSource;
        IGageRehypoSource floatSource;
        UnlockCheckedHook hook;
        PoolKey key;
    }

    /// @notice The release step. Env: `POOL_MANAGER`, `GENERATION_DEPLOYER`, and `PRICE_SOURCE`, the chain's Nuntius
    /// price source, the only one the factory's priced sources may centre on (zero, or unset, for stable sources only).
    function run() external returns (address factory) {
        address deployer = msg.sender;
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address registry = vm.envAddress("GENERATION_DEPLOYER");
        address priceSource = vm.envOr("PRICE_SOURCE", address(0));
        vm.startBroadcast(deployer);
        factory = deployFactory(poolManager, registry, priceSource);
        vm.stopBroadcast();
        console2.log("GageRehypoSourceFactory", factory);
    }

    /// @notice Deploy the factory. It keeps its registry and its price source for good, so an address that does not
    /// answer `isFactory` is refused first, and a price source must answer `USDG()`.
    function deployFactory(IPoolManager poolManager, address registry, address priceSource)
        public
        returns (address factory)
    {
        try IIntentFactoryRegistry(registry).isFactory(address(0)) returns (bool) {}
        catch {
            revert("GENERATION_DEPLOYER does not answer isFactory: not the generation deployer");
        }
        if (priceSource != address(0)) {
            try IPriceSourceUsdg(priceSource).USDG() returns (address) {}
            catch {
                revert("PRICE_SOURCE does not answer USDG: not a Nuntius price source");
            }
        }
        factory = deployCode(FACTORY_ARTIFACT, abi.encode(poolManager, registry, priceSource));
    }

    /// @notice The stable rehearsal, never on chain 4663. The broadcaster is the partner: owner and beneficiary of both
    /// sources. Env: `REHYPO_FACTORY`, `LEND_TOKEN`, `LEND_VAULT`, `FLOAT_TOKEN`, `KEEPER`, `SEED_LEND`, `SEED_FLOAT`
    /// (raw units), and optionally `LEND_FLOAT_BPS` (default 2000, from 100 to 10,000), `RANGE_TICKS` (default 0, the
    /// full range; up to 1,774,544; non-zero, the hook this script deploys anchors a range that wide on parity and both
    /// sides take `LEND_FLOAT_BPS`), `FAILSAFE_BPS` (default 0, at most 1,000: the failsafe, design 2.5, the lent
    /// source's and on a declared range the float-only source's too) and `REHYPO_SALT`. A value outside its bounds is refused, never cut to fit.
    function rehearse() external returns (Plugged memory p) {
        RehypoSourceSettings memory stable;
        stable.rangeTicks = uint24(_envBounded("RANGE_TICKS", 0, 0, MAX_RANGE_TICKS));
        p = _rehearse(stable, ONE, 0);
    }

    /// @notice The priced rehearsal, never on chain 4663: an X/USDG pool, X float-only and USDG lent, both sources
    /// centring their band on the price the Nuntius source verifies. The pool starts at `PRICE_8` USDG an X, the price
    /// a fresh Nuntius report signs. Env: as `rehearse` with `LEND_TOKEN` USDG and `FLOAT_TOKEN` the priced token, plus
    /// `PRICE_SOURCE`, `PRICE_8`, and optionally `PRICED_BAND_BPS` (default 100, from 10 to 300) and `PRICED_MOVE_BPS`
    /// (default 500, from 1 to 1,000).
    function rehearsePriced() external returns (Plugged memory p) {
        RehypoSourceSettings memory priced = RehypoSourceSettings({
            rangeTicks: uint24(_envBounded("RANGE_TICKS", 0, 0, MAX_RANGE_TICKS)),
            priceSource: vm.envAddress("PRICE_SOURCE"),
            pricedToken: vm.envAddress("FLOAT_TOKEN"),
            bandBps: uint16(_envBounded("PRICED_BAND_BPS", PRICED_BAND_BPS, MIN_BAND_BPS, MAX_BAND_BPS)),
            centreMoveBps: uint16(_envBounded("PRICED_MOVE_BPS", PRICED_MOVE_BPS, 1, MAX_CENTRE_MOVE_BPS))
        });
        p = _rehearse(priced, vm.envUint("PRICE_8"), 0);
    }

    /// @notice The pegged rehearsal, never on chain 4663: a dollar stable against USDG (frxUSD/USDG), the stable
    /// float-only and USDG lent, both sources centring their band on the stable's signed price, a keeper move only
    /// while it is within the peg of a dollar, and inside the band the whole float open. Env: as `rehearsePriced`, with
    /// `PRICE_SOURCE` the factory's price router (the stable's feed named on it), `PRICE_8` defaulting to a dollar,
    /// `PEGGED_BAND_BPS` (default 50, from 10 to 300), `PEGGED_MOVE_BPS` (default 100, from 1 to 1,000) and `PEG_BPS`
    /// (default 50, from 10 to 100).
    function rehearsePegged() external returns (Plugged memory p) {
        RehypoSourceSettings memory pegged = RehypoSourceSettings({
            rangeTicks: uint24(_envBounded("RANGE_TICKS", 0, 0, MAX_RANGE_TICKS)),
            priceSource: vm.envAddress("PRICE_SOURCE"),
            pricedToken: vm.envAddress("FLOAT_TOKEN"),
            bandBps: uint16(_envBounded("PEGGED_BAND_BPS", PEGGED_BAND_BPS, MIN_BAND_BPS, MAX_BAND_BPS)),
            centreMoveBps: uint16(_envBounded("PEGGED_MOVE_BPS", PEGGED_MOVE_BPS, 1, MAX_CENTRE_MOVE_BPS))
        });
        p = _rehearse(
            pegged, vm.envOr("PRICE_8", ONE), uint16(_envBounded("PEG_BPS", PEG_BPS, MIN_BAND_BPS, MAX_PEG_BPS))
        );
    }

    function _rehearse(RehypoSourceSettings memory settings, uint256 price8, uint16 pegBps)
        internal
        returns (Plugged memory p)
    {
        FeeRule memory fee = FeeRule({
            module: vm.envOr("FEE_MODULE", address(0)),
            poolId: PoolId.wrap(vm.envOr("FEE_POOL_ID", bytes32(0))),
            floor: uint24(_envBounded("FEE_FLOOR", FEE_FLOOR, FEE_FLOOR, MAX_FEE_CAP)),
            cap: uint24(_envBounded("FEE_CAP", FEE_CAP, FEE_FLOOR, MAX_FEE_CAP))
        });
        p = setUpPool(
            Pool({
                factory: IGageRehypoSourceFactory(vm.envAddress("REHYPO_FACTORY")),
                lend: IERC20(vm.envAddress("LEND_TOKEN")),
                vault: vm.envAddress("LEND_VAULT"),
                floatBps: uint16(_envBounded("LEND_FLOAT_BPS", 2000, MIN_FLOAT_BPS, BPS)),
                floatOnly: IERC20(vm.envAddress("FLOAT_TOKEN")),
                keeper: vm.envAddress("KEEPER"),
                seedLend: vm.envUint("SEED_LEND"),
                seedFloat: vm.envUint("SEED_FLOAT"),
                salt: vm.envOr("REHYPO_SALT", bytes32(0)),
                settings: settings,
                price8: price8,
                failsafeBps: uint16(_envBounded("FAILSAFE_BPS", 0, 0, MAX_FAILSAFE_BPS)),
                pegBps: pegBps
            }),
            fee
        );
        console2.log("lent source      ", address(p.lendSource));
        console2.log("float-only source", address(p.floatSource));
        console2.log("hook             ", address(p.hook));
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(p.key.toId()));
        console2.log(string.concat("gage keeper entry, rehypo-sources.", vm.toString(block.chainid), ".json:"));
        console2.log(keeperFile(p));
    }

    /// @notice The partner's set-up, in the guide's order, from the caller. A pool whose sources declare a range gives
    /// both sides the lent side's float target, and, when stable, makes the first keeper move on a hundredth of the
    /// seed before the rest goes in: until a source's first move nothing caps what swaps may take inside the band.
    function setUpPool(Pool memory pool) public returns (Plugged memory p) {
        return setUpPool(pool, FeeRule(address(0), PoolId.wrap(bytes32(0)), 0, 0));
    }

    /// @notice `setUpPool` with a fee rule: the pool is then a dynamic-fee pool on the kit's fee hook, each swap paying
    /// what the rule's module quotes inside its bounds. No rule (a zero module) is the static-fee set-up.
    function setUpPool(Pool memory pool, FeeRule memory fee) public returns (Plugged memory p) {
        require(
            block.chainid != MAINNET,
            "the rehearsal never runs on chain 4663: there the partner's Safe makes these calls"
        );
        address partner = msg.sender;
        IPoolManager poolManager = pool.factory.POOL_MANAGER();
        // The sources' addresses ahead of time: a Safe batch names them in the hook's constructor before they exist.
        (address lendAt, address floatAt) = _predictSources(pool, partner);
        require(
            lendAt.code.length == 0 && floatAt.code.length == 0,
            "a source already exists at this address: set another REHYPO_SALT"
        );
        bool lendFirst = address(pool.lend) < address(pool.floatOnly);

        vm.startBroadcast(partner);
        // 1. One source per pool token.
        _createSources(pool, partner, lendAt, floatAt);
        // 2. The hook, naming the two sources in currency order; one that asks for the vault failsafe when it is on, at
        // the fee a draw must earn in each token.
        p.hook = _hookFor(pool, fee, poolManager, lendFirst ? lendAt : floatAt, lendFirst ? floatAt : lendAt, lendFirst);
        // 3. The pool, at its starting price: one whole unit for one whole unit when pegged.
        p.key = PoolKey({
            currency0: Currency.wrap(lendFirst ? address(pool.lend) : address(pool.floatOnly)),
            currency1: Currency.wrap(lendFirst ? address(pool.floatOnly) : address(pool.lend)),
            fee: fee.module == address(0) ? FEE : LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(p.hook))
        });
        poolManager.initialize(p.key, _startPrice(p.key, address(pool.floatOnly), pool.price8));
        // 4. Each source takes the pool's hook as its one depositor.
        IGageRehypoSource(lendAt).bind(p.key);
        IGageRehypoSource(floatAt).bind(p.key);
        // 5. gage's keeper rebalances both sides (the float-only one too, since the 8 November generation).
        IGageRehypoSource(lendAt).setKeeper(pool.keeper, true);
        IGageRehypoSource(floatAt).setKeeper(pool.keeper, true);
        p.lendSource = IGageRehypoSource(lendAt);
        p.floatSource = IGageRehypoSource(floatAt);
        // 6. The seed, through the hook: on a declared stable pool a hundredth of it first, then the first keeper move,
        // then the rest.
        (uint256 seed0, uint256 seed1) = lendFirst ? (pool.seedLend, pool.seedFloat) : (pool.seedFloat, pool.seedLend);
        pool.lend.approve(address(p.hook), pool.seedLend);
        pool.floatOnly.approve(address(p.hook), pool.seedFloat);
        (uint256 first0, uint256 first1) = (seed0 / FIRST_SEED_SHARE, seed1 / FIRST_SEED_SHARE);
        bool firstMove = pool.settings.rangeTicks != 0 && pool.settings.priceSource == address(0)
            && Math.sqrt(first0 * first1) >= MIN_SEED_SHARES;
        if (!firstMove) {
            p.hook.seedLiquidity(seed0, seed1);
        } else {
            p.hook.seedLiquidity(first0, first1);
            _firstMove(p, pool.keeper, partner);
            _addRest(p, seed0 - first0, seed1 - first1);
        }
        vm.stopBroadcast();
    }

    /// @dev The first keeper move on both sources of a declared stable pool, with the keeper's band: the move that sets
    /// each source's cap inside the band (`swapCap`), before which the anchored hook holds the full range. The partner
    /// makes it as a keeper for these two calls when it is not gage's keeper itself, as its Safe would in one batch.
    function _firstMove(Plugged memory p, address keeper, address partner) internal {
        bool temporary = keeper != partner;
        if (temporary) {
            p.lendSource.setKeeper(partner, true);
            p.floatSource.setKeeper(partner, true);
        }
        (uint160 lo, uint160 hi) = band(p.key);
        p.lendSource.rebalance(lo, hi);
        p.floatSource.rebalance(lo, hi);
        if (temporary) {
            p.lendSource.setKeeper(partner, false);
            p.floatSource.setKeeper(partner, false);
        }
    }

    /// @dev The rest of the seed after the first move, in the shares it buys at the hook's ratio (what the sources hold
    /// for the hook now, OpenZeppelin's virtual offset included), never more than `rest0` and `rest1`.
    function _addRest(Plugged memory p, uint256 rest0, uint256 rest1) internal {
        bool lendFirst = p.lendSource.asset() == Currency.unwrap(p.key.currency0);
        (IGageRehypoSource source0, IGageRehypoSource source1) =
            lendFirst ? (p.lendSource, p.floatSource) : (p.floatSource, p.lendSource);
        uint256 supply = p.hook.totalSupply() + 1e6;
        uint256 held0 = source0.convertToAssets(source0.balanceOf(address(p.hook))) + 1;
        uint256 held1 = source1.convertToAssets(source1.balanceOf(address(p.hook))) + 1;
        uint256 shares = Math.min(Math.mulDiv(rest0, supply, held0), Math.mulDiv(rest1, supply, held1));
        p.hook.addReHypothecatedLiquidity(shares, rest0, rest1);
    }

    /// @dev The least fee a vault failsafe draw must earn in each token: `DRAW_COST_8` dollars in USDG (the lent side)
    /// and in the float-only token at the pool's starting price (`price8` USDG for one whole token).
    function _drawFees(Pool memory pool) internal view returns (uint256 lend, uint256 floatOnly) {
        lend = Math.mulDiv(10 ** IERC20Metadata(address(pool.lend)).decimals(), DRAW_COST_8, ONE);
        floatOnly = Math.mulDiv(10 ** IERC20Metadata(address(pool.floatOnly)).decimals(), DRAW_COST_8, pool.price8);
    }

    /// @dev The float-only source's target: all its backing on the full range, the lent side's on a declared range.
    function _floatOnlyBps(Pool memory pool) internal pure returns (uint16) {
        return pool.settings.rangeTicks == 0 ? ALL_FLOAT : pool.floatBps;
    }

    /// @dev The float-only source's failsafe: the pool's on a declared range, where that source keeps the float beyond
    /// its target closed and the anchored failsafe hooks ask both sources; none on the full range, where its whole
    /// float is open already.
    function _floatOnlyFailsafe(Pool memory pool) internal pure returns (uint16) {
        return pool.settings.rangeTicks == 0 ? 0 : pool.failsafeBps;
    }

    /// @dev An environment value, or `fallback_` when unset, refused outside [`lo`, `hi`].
    function _envBounded(string memory name, uint256 fallback_, uint256 lo, uint256 hi)
        internal
        view
        returns (uint256 value)
    {
        value = vm.envOr(name, fallback_);
        require(
            value >= lo && value <= hi,
            string.concat(name, " must be from ", vm.toString(lo), " to ", vm.toString(hi), ": refused, not cut to fit")
        );
    }

    /// @dev Where the factory will put the lent source (with the pool's failsafe) and the float-only one (on a declared
    /// range the lent side's float target and the same failsafe; on the full range all float and none).
    function _predictSources(Pool memory pool, address partner)
        internal
        view
        returns (address lendAt, address floatAt)
    {
        lendAt = pool.factory
            .predict(
                partner,
                pool.lend,
                pool.vault,
                partner,
                partner,
                pool.floatBps,
                pool.settings,
                pool.failsafeBps,
                pool.pegBps,
                pool.salt
            );
        floatAt = pool.factory
            .predict(
                partner,
                pool.floatOnly,
                address(0),
                partner,
                partner,
                _floatOnlyBps(pool),
                pool.settings,
                _floatOnlyFailsafe(pool),
                pool.pegBps,
                pool.salt
            );
    }

    /// @dev Create both sources, each where `_predictSources` said.
    function _createSources(Pool memory pool, address partner, address lendAt, address floatAt) internal {
        require(
            pool.factory
                .create(
                    pool.lend,
                    pool.vault,
                    partner,
                    partner,
                    pool.floatBps,
                    pool.settings,
                    pool.failsafeBps,
                    pool.pegBps,
                    pool.salt
                ) == lendAt,
            "lent source not at its predicted address"
        );
        require(
            pool.factory
                .create(
                    pool.floatOnly,
                    address(0),
                    partner,
                    partner,
                    _floatOnlyBps(pool),
                    pool.settings,
                    _floatOnlyFailsafe(pool),
                    pool.pegBps,
                    pool.salt
                ) == floatAt,
            "float-only source not at its predicted address"
        );
    }

    /// @notice The keeper's band for a stable pool: `BAND_BPS` either side of one whole unit for one whole unit.
    function band(PoolKey memory key) public view returns (uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) {
        return (_sqrtPriceX96(key, BPS - BAND_BPS), _sqrtPriceX96(key, BPS + BAND_BPS));
    }

    /// @notice gage's keeper entry (`rehypo-sources.<chainId>.json`) for the pool: both sides, each with the band when
    /// stable (a priced source centres its own on the signed price, so its entry carries none).
    function keeperFile(Plugged memory p) public view returns (string memory) {
        return string.concat(
            '{ "schemaVersion": 1, "chainId": ',
            vm.toString(block.chainid),
            ', "sources": [ ',
            _keeperEntry(p, p.lendSource),
            ", ",
            _keeperEntry(p, p.floatSource),
            " ] }"
        );
    }

    function _keeperEntry(Plugged memory p, IGageRehypoSource source) internal view returns (string memory entry) {
        entry = string.concat(
            '{ "name": "',
            _symbol(Currency.unwrap(p.key.currency0)),
            "/",
            _symbol(Currency.unwrap(p.key.currency1)),
            ", ",
            _symbol(source.asset()),
            ' side", "source": "',
            vm.toString(address(source)),
            '"'
        );
        if (source.PRICED_TOKEN() == address(0)) {
            (uint160 lo, uint160 hi) = band(p.key);
            entry = string.concat(
                entry, ', "minSqrtPriceX96": "', vm.toString(lo), '", "maxSqrtPriceX96": "', vm.toString(hi), '"'
            );
        }
        entry = string.concat(entry, " }");
    }

    /// @dev Mine a salt whose CREATE2 address from the deterministic deployer carries the hook's flags, then deploy
    /// there (a broadcast `new` with a salt goes through that deployer). `failsafe`: the hook that asks for the vault
    /// failsafe (`FailsafeUnlockCheckedHook`, the same permissions). When both sources declare a range, its anchored form
    /// (`AnchoredUnlockCheckedHook`, `AnchoredFailsafeUnlockCheckedHook`): the range fixed on the sources' anchor and
    /// sized there, the only narrow shape a declared source supports (docs/rehypo-source.md, item 6). A failsafe hook
    /// draws only when the swap's fee covers `drawFee0` or `drawFee1` (the output token's) and `FORGONE_PIPS`.
    function _deployHook(
        IPoolManager poolManager,
        address source0,
        address source1,
        bool failsafe,
        uint256 drawFee0,
        uint256 drawFee1
    ) internal virtual returns (UnlockCheckedHook hook) {
        bool anchored = IGageRehypoSource(source0).RANGE_TICKS() != 0 && IGageRehypoSource(source1).RANGE_TICKS() != 0;
        bytes memory code = anchored
            ? (failsafe
                    ? type(AnchoredFailsafeUnlockCheckedHook).creationCode
                    : type(AnchoredUnlockCheckedHook).creationCode)
            : (failsafe ? type(FailsafeUnlockCheckedHook).creationCode : type(UnlockCheckedHook).creationCode);
        bytes memory args = failsafe
            ? abi.encode(poolManager, source0, source1, drawFee0, drawFee1, FORGONE_PIPS)
            : abi.encode(poolManager, source0, source1);
        (address at, bytes32 salt) = _mineHook(abi.encodePacked(code, args));
        if (anchored) {
            hook = failsafe
                ? UnlockCheckedHook(
                    new AnchoredFailsafeUnlockCheckedHook{salt: salt}(
                        poolManager, source0, source1, drawFee0, drawFee1, FORGONE_PIPS
                    )
                )
                : UnlockCheckedHook(new AnchoredUnlockCheckedHook{salt: salt}(poolManager, source0, source1));
        } else {
            hook = failsafe
                ? new FailsafeUnlockCheckedHook{salt: salt}(
                    poolManager, source0, source1, drawFee0, drawFee1, FORGONE_PIPS
                )
                : new UnlockCheckedHook{salt: salt}(poolManager, source0, source1);
        }
        require(address(hook) == at, "hook address differs from the mined one");
    }

    /// @dev The pool's hook: the kit's fee hook with a fee rule, the static-fee one without.
    function _hookFor(
        Pool memory pool,
        FeeRule memory fee,
        IPoolManager poolManager,
        address source0,
        address source1,
        bool lendFirst
    ) internal returns (UnlockCheckedHook) {
        // In currency order: the lent side's first when it is currency0.
        (uint256 drawFee0, uint256 drawFee1) = _drawFees(pool);
        if (!lendFirst) (drawFee0, drawFee1) = (drawFee1, drawFee0);
        if (fee.module == address(0)) {
            return _deployHook(poolManager, source0, source1, pool.failsafeBps != 0, drawFee0, drawFee1);
        }
        return _deployFeeHook(poolManager, source0, source1, pool.failsafeBps != 0, drawFee0, drawFee1, fee);
    }

    /// @dev The kit's fee hook for a dynamic-fee pool (`AnchoredFeeHook`; `AnchoredFailsafeFeeHook` when the lent source
    /// has the failsafe), deployed as `_deployHook` deploys the others. The fee hooks are anchored hooks: both sources
    /// must declare a range.
    function _deployFeeHook(
        IPoolManager poolManager,
        address source0,
        address source1,
        bool failsafe,
        uint256 drawFee0,
        uint256 drawFee1,
        FeeRule memory fee
    ) internal virtual returns (UnlockCheckedHook hook) {
        require(
            IGageRehypoSource(source0).RANGE_TICKS() != 0 && IGageRehypoSource(source1).RANGE_TICKS() != 0,
            "a fee rule needs both sources to declare a range: the kit's fee hooks are anchored hooks"
        );
        if (!failsafe) return _newFeeHook(poolManager, source0, source1, fee);
        return _newFailsafeFeeHook(
            FailsafeFeeArgs({
                poolManager: poolManager,
                source0: source0,
                source1: source1,
                drawFee0: drawFee0,
                drawFee1: drawFee1,
                forgonePips: FORGONE_PIPS,
                floor: fee.floor,
                cap: fee.cap,
                module: fee.module,
                poolId: fee.poolId
            })
        );
    }

    function _newFeeHook(IPoolManager poolManager, address source0, address source1, FeeRule memory fee)
        private
        returns (UnlockCheckedHook hook)
    {
        (address at, bytes32 salt) = _mineHook(
            abi.encodePacked(
                type(AnchoredFeeHook).creationCode,
                abi.encode(poolManager, source0, source1, fee.floor, fee.cap, fee.module, fee.poolId)
            )
        );
        hook = UnlockCheckedHook(
            new AnchoredFeeHook{salt: salt}(poolManager, source0, source1, fee.floor, fee.cap, fee.module, fee.poolId)
        );
        require(address(hook) == at, "hook address differs from the mined one");
    }

    /// @dev `AnchoredFailsafeFeeHook`'s constructor arguments, in its order: as a struct they encode as the ten values
    /// do, and fit one function.
    struct FailsafeFeeArgs {
        IPoolManager poolManager;
        address source0;
        address source1;
        uint256 drawFee0;
        uint256 drawFee1;
        uint24 forgonePips;
        uint24 floor;
        uint24 cap;
        address module;
        PoolId poolId;
    }

    function _newFailsafeFeeHook(FailsafeFeeArgs memory a) private returns (UnlockCheckedHook hook) {
        (address at, bytes32 salt) =
            _mineHook(abi.encodePacked(type(AnchoredFailsafeFeeHook).creationCode, abi.encode(a)));
        hook = UnlockCheckedHook(
            new AnchoredFailsafeFeeHook{salt: salt}(
                a.poolManager,
                a.source0,
                a.source1,
                a.drawFee0,
                a.drawFee1,
                a.forgonePips,
                a.floor,
                a.cap,
                a.module,
                a.poolId
            )
        );
        require(address(hook) == at, "hook address differs from the mined one");
    }

    /// @dev A CREATE2 salt that puts `initCode` at an address with exactly the reference hook's permission flags and
    /// no code yet: HookMiner's rule and search, with the init code hashed once rather than at every salt.
    function _mineHook(bytes memory initCode) internal view returns (address at, bytes32 salt) {
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i; i < 160_444; ++i) {
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), CREATE2_FACTORY, i, codeHash)))));
            if (uint160(at) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && at.code.length == 0) return (at, bytes32(i));
        }
        revert("no hook salt found");
    }

    /// @dev floor(sqrt(price × 10^decimals1 / 10^decimals0) × 2^96), for a price of `bps / 10,000` whole currency1 per
    /// whole currency0 ("Rehypo sources"). Exact: the floor of the root of a floor is the
    /// floor of the root.
    function _sqrtPriceX96(PoolKey memory key, uint256 bps) internal view returns (uint160) {
        uint256 unit0 = 10 ** IERC20Metadata(Currency.unwrap(key.currency0)).decimals();
        uint256 unit1 = 10 ** IERC20Metadata(Currency.unwrap(key.currency1)).decimals();
        return uint160(Math.sqrt(Math.mulDiv(bps * unit1, 1 << 192, BPS * unit0)));
    }

    /// @dev The pool's starting sqrt price for `price8` whole lent units per whole float-only unit (eight decimals),
    /// in whichever currency order the pool has. `ONE` gives `_sqrtPriceX96(key, BPS)` exactly.
    function _startPrice(PoolKey memory key, address floatOnly, uint256 price8) internal view returns (uint160) {
        uint256 unit0 = 10 ** IERC20Metadata(Currency.unwrap(key.currency0)).decimals();
        uint256 unit1 = 10 ** IERC20Metadata(Currency.unwrap(key.currency1)).decimals();
        (uint256 num, uint256 den) = Currency.unwrap(key.currency0) == floatOnly ? (price8, ONE) : (ONE, price8);
        return uint160(Math.sqrt(Math.mulDiv(num * unit1, 1 << 192, den * unit0)));
    }

    function _symbol(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }
}
