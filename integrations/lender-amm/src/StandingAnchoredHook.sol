// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {UnlockCheckedHook} from "./UnlockCheckedHook.sol";
import {IGageRehypoSourceFailsafe} from "./FailsafeUnlockCheckedHook.sol";
import {AnchoredRange, IGageRehypoSourceAnchor} from "./AnchoredUnlockCheckedHook.sol";

/// @notice What a standing hook reads on a gage rehypo source beyond the anchored range's getters: its owner, who
/// names the hook's keepers as it names the source's.
interface IGageRehypoSourceOwner {
    function owner() external view returns (address);
}

/// @notice The anchored range (`AnchoredRange`) as a position that stays in the pool. The kit's anchored hooks add
/// their position before every swap and remove it after, settling both coins through the sources each time; a gage
/// source's float earns nothing while it waits, so that buys no yield, and between two keeper moves the position is
/// the same from swap to swap. This hook places it once and leaves it: a swap that finds the position in place calls
/// no source and moves no token through the hook, and nothing runs after a swap (the hook holds no `afterSwap`
/// permission).
///
/// Placing sizes the position as the anchored hook sizes one: on the full range until both sources hold a cap from a
/// keeper move, then on the anchored range, at the anchor from what each source offers a swap (`maxWithdraw` inside
/// an unlock), or at the liquidity it held when it was last taken out, scaled by the LP moves since, while neither
/// source's swap float has moved by anything but this hook. Adding the liquidity leaves the hook owing both coins; the
/// source pays a debt its depositor owes the PoolManager inside an unlock, so the hook withdraws exactly that and
/// settles. Taking out removes the whole position with its fees inside an unlock of the hook's own and deposits both
/// coins, which a source never refuses inside an unlock.
///
/// The position is taken out for three things only. A keeper move: the hook is the keeper of both sources and has
/// keepers of its own, and one call (`rebalance` on a stable pair, `rebalanceAt` on a priced or pegged one) takes the
/// position out and moves both sources; if either source refuses, the call reverts and the position stays as it was.
/// The move places nothing: the first swap after it places the position, sized afresh, and pays for the placing, as
/// the first swap after any take-out does. Until that swap the sources hold everything. An LP entry or exit, and the seed: they take it out first, so the sources hold everything when
/// shares are priced, and the next swap places it again at the held liquidity scaled by the shares, never sized afresh.
/// And `takeOut`, for the hook's keepers and LP-share holders (an LP takes it out before `exitNow` on a source, which
/// reads the source alone). While the position is in, a source's `totalAssets` leaves it out: `positionAmounts` is what
/// a reader adds, and the hook's own share quotes (`previewMint`, `previewRedeem`) count it.
///
/// A swap's input stays in the position until it is next taken out, where an anchored hook's joins the source's swap
/// float only up to its cap at every swap. A pegged source has no cap inside the band and a priced one none below its
/// float target at the width where its cap stops binding: the repeat rounds (`test/StandingRepeat.t.sol`) hold this
/// hook to the bound on those. A stable source declared narrower than the full range caps its swap float inside the
/// band and is not proven here.
///
/// Only this hook may be named keeper on its sources: a move sent to a source directly while the position is in the
/// pool would size that source's float without it.
abstract contract StandingPosition is UnlockCheckedHook, AnchoredRange, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @dev The position in the pool: its liquidity (zero while it is out), its range, and whether the next swap may
    /// still ask the sources for more (`_ask`, the failsafe hooks').
    struct Standing {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        bool mayAsk;
    }

    /// @dev The two sources, token0's and token1's: the hook is their depositor and their keeper.
    address internal immutable SOURCE_0;
    address internal immutable SOURCE_1;

    /// @notice The accounts that may move the sources through this hook and take the position out.
    mapping(address keeper => bool allowed) public isKeeper;

    Standing private _standing;

    event KeeperSet(address indexed keeper, bool allowed);

    /// @notice The caller owns neither source, or not both.
    error NotSourceOwner();
    error NotKeeper();
    error NotKeeperOrHolder();

    /// @param source0 The source of the pool's currency0, the hook's first yield source.
    /// @param source1 The source of the pool's currency1.
    constructor(address source0, address source1) {
        (SOURCE_0, SOURCE_1) = (source0, source1);
    }

    // ---------------------------------------------------------------- keepers

    /// @notice Allow or stop an account moving the sources through this hook. The owner of both sources names the
    /// hook's keepers, as it names each source's (where it names this hook, and no one else).
    /// @param keeper The account.
    /// @param allowed Whether it may call `rebalance`, `rebalanceAt` and `takeOut`.
    function setKeeper(address keeper, bool allowed) external {
        if (
            msg.sender != IGageRehypoSourceOwner(SOURCE_0).owner()
                || msg.sender != IGageRehypoSourceOwner(SOURCE_1).owner()
        ) revert NotSourceOwner();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice A stable pair's keeper move, in one transaction: take the position out and call `rebalance` with this
    /// band on both sources as their keeper. The next swap places the position again on what they then open. Reverts
    /// whole if either source refuses (a priced source does). Keepers only, outside an unlock.
    /// @param minSqrtPriceX96 The lowest pool price, as a v4 sqrt price, at which the sources open swaps in full.
    /// @param maxSqrtPriceX96 The highest.
    function rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) external {
        (minSqrtPriceX96, maxSqrtPriceX96);
        _move();
    }

    /// @notice A priced or pegged pair's keeper move, in one transaction: take the position out and call `rebalanceAt`
    /// with this report on both sources as their keeper. The next swap places the position again on what they then
    /// open. Reverts whole if either source refuses (a stale report, a price off the peg, a stable source). Keepers
    /// only, outside an unlock.
    /// @param report An ABI-encoded Nuntius signed price, as the sources' `rebalanceAt` takes it.
    function rebalanceAt(bytes calldata report) external {
        report;
        _move();
    }

    /// @notice Take the position out of the pool into the sources, with its fees; nothing if it is out already. The
    /// next swap places it again. For the hook's keepers and for LP-share holders, outside an unlock.
    function takeOut() external {
        if (!isKeeper[msg.sender] && balanceOf(msg.sender) == 0) revert NotKeeperOrHolder();
        _takeOut();
    }

    /// @notice The PoolManager's callback for this hook's own unlocks, which take the position out. Placing needs no
    /// unlock of the hook's own: it happens in a swap's.
    /// @dev The PoolManager calls back only the account that unlocked it, so only this hook's own unlocks reach here.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        _remove();
        return "";
    }

    // ---------------------------------------------------------------- views

    /// @notice The position in the pool: its liquidity, zero while it is out, and its range.
    function position() public view returns (uint128 liquidity, int24 tickLower, int24 tickUpper) {
        Standing memory s = _standing;
        return (s.liquidity, s.tickLower, s.tickUpper);
    }

    /// @notice Both coins the position's liquidity holds at the pool's price, rounded down as taking it out pays them:
    /// what a reader adds to the sources' `totalAssets` while the position is in. The swap fees the position has
    /// earned since it was placed are not counted: they stay in the pool until it is next taken out, and join the
    /// sources then. Zeros while it is out.
    function positionAmounts() public view returns (uint256 amount0, uint256 amount1) {
        (uint128 liquidity, int24 lower, int24 upper) = position();
        if (liquidity == 0) return (0, 0);
        (uint160 p,,,) = poolManager.getSlot0(getPoolKey().toId());
        return _principal(p, liquidity, lower, upper);
    }

    /// @dev Both coins `liquidity` holds on [`lower`, `upper`] at the pool's price `p`, rounded down as a removal pays
    /// them, fees apart.
    function _principal(uint160 p, uint128 liquidity, int24 lower, int24 upper)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 l = TickMath.getSqrtPriceAtTick(lower);
        uint160 u = TickMath.getSqrtPriceAtTick(upper);
        if (p < u) amount0 = SqrtPriceMath.getAmount0Delta(p > l ? p : l, u, liquidity, false);
        if (p > l) amount1 = SqrtPriceMath.getAmount1Delta(l, p < u ? p : u, liquidity, false);
    }

    /// @notice The lower tick the next placing takes: the anchored range's, or the full range's.
    function getTickLower() public view override returns (int24 lower) {
        (, lower,) = _range();
    }

    /// @notice The upper tick the next placing takes.
    function getTickUpper() public view override returns (int24 upper) {
        (,, upper) = _range();
    }

    /// @dev The range a placing takes now: the anchored range, or the full range (`full`) where the anchored hook
    /// takes it.
    function _range() internal view returns (bool full, int24 lower, int24 upper) {
        int24 spacing = getPoolKey().tickSpacing;
        (full, lower, upper) = _anchoredRange(spacing);
        if (full) (lower, upper) = (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
    }

    /// @notice The anchored hooks' permissions less `afterSwap`: the position stays in, so nothing follows a swap.
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.afterSwap = false;
    }

    // ---------------------------------------------------------------- LP moves

    /// @notice OpenZeppelin's seed, outside an unlock, the position taken out first.
    function seedLiquidity(uint256 amount0, uint256 amount1)
        public
        payable
        override
        returns (uint256 shares, BalanceDelta delta)
    {
        _takeOut();
        return ReHypothecationHook.seedLiquidity(amount0, amount1);
    }

    /// @notice OpenZeppelin's LP entry, outside an unlock, the position taken out first so the sources hold everything
    /// the shares are priced on. The next swap places the position again at the held liquidity scaled by the shares.
    function addReHypothecatedLiquidity(uint256 shares, uint256 amount0Max, uint256 amount1Max)
        public
        payable
        override
        returns (BalanceDelta delta)
    {
        (bool held, uint256 supply, int24 lower, int24 upper) = _beforeLpMove();
        delta = ReHypothecationHook.addReHypothecatedLiquidity(shares, amount0Max, amount1Max);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    /// @notice OpenZeppelin's LP exit, outside an unlock, the position taken out first. The next swap places the
    /// position again at the held liquidity scaled by the shares.
    function removeReHypothecatedLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        public
        override
        returns (BalanceDelta delta)
    {
        (bool held, uint256 supply, int24 lower, int24 upper) = _beforeLpMove();
        delta = ReHypothecationHook.removeReHypothecatedLiquidity(shares, amount0Min, amount1Min);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    /// @dev The position out, then what `_rescale` needs after the move: whether the liquidity taken out is held on
    /// the range a placing takes now, and the share supply before the move.
    function _beforeLpMove() private returns (bool held, uint256 supply, int24 lower, int24 upper) {
        _takeOut();
        (, lower, upper) = _range();
        (held, supply) = (_holds(lower, upper), totalSupply());
    }

    /// @dev The pool's tokens are ERC-20s (a pool with the native currency never binds): OpenZeppelin's transfers
    /// without their native branch.
    function _transferFromSenderToHook(Currency currency, uint256 amount, address sender) internal override {
        IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(this), amount);
    }

    function _transferFromHookToSender(Currency currency, uint256 amount, address sender) internal override {
        IERC20(Currency.unwrap(currency)).safeTransfer(sender, amount);
    }

    /// @dev What the shares are priced on: the source's count and, while the position is in the pool, its part of it,
    /// so a quote read with the position in is what the move pays once it has taken the position out.
    function _getAmountInYieldSource(Currency currency) internal view override returns (uint256 amount) {
        (uint256 amount0, uint256 amount1) = positionAmounts();
        amount = super._getAmountInYieldSource(currency) + (currency == getPoolKey().currency0 ? amount0 : amount1);
    }

    // ---------------------------------------------------------------- swaps

    /// @dev Nothing for a position in place. A position that is out is placed first, and one the failsafe may still
    /// deepen asks (`_ask`), both under the reentrancy guard: no swap runs inside an LP move, a keeper move, a take-out
    /// or another swap's placing.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24 fee)
    {
        if (_reentrancyGuardEntered()) revert JITLocked();
        fee = _swapFee(key, params);
        if (_standing.liquidity == 0 || _standing.mayAsk) _prepare(key, params, fee);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /// @dev Never called: the hook holds no `afterSwap` permission.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @dev The fee a hook names for this swap, with v4's override flag, or zero to leave the pool's own.
    function _swapFee(PoolKey calldata, SwapParams calldata) internal view virtual returns (uint24) {
        return 0;
    }

    /// @dev Whether a position sized afresh on the anchored range lets its first swap ask the sources for more.
    function _asks() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev The ask of a position its first swap may still deepen: nothing on a hook without the failsafe.
    function _ask(PoolKey calldata key, SwapParams calldata params, uint24 fee) internal virtual {}

    function _prepare(PoolKey calldata key, SwapParams calldata params, uint24 fee) private nonReentrant {
        if (_standing.liquidity == 0 && _place() == 0) revert NoUsableLiquidity();
        if (_standing.mayAsk) {
            _standing.mayAsk = false;
            _ask(key, params, fee);
        }
    }

    // ---------------------------------------------------------------- the position

    /// @dev One keeper move: the position out, then the keeper's own call sent on to both sources (the entry's
    /// selector and arguments are the source's). A source's refusal is the call's. Nothing is placed here: the first
    /// swap after the move places the position and pays for it, so a move costs the keeper the sources' two moves and
    /// one removal.
    function _move() private nonReentrant {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        if (_standing.liquidity != 0) poolManager.unlock("");
        _forward(SOURCE_0);
        _forward(SOURCE_1);
    }

    function _forward(address source) private {
        (bool ok, bytes memory reason) = source.call(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @dev Outside an unlock: the position into the sources, if it is in the pool.
    function _takeOut() private nonReentrant {
        _requireLocked();
        if (_standing.liquidity != 0) poolManager.unlock("");
    }

    /// @dev Inside an unlock: place the position on the range a swap would use now, from what the sources offer, and
    /// pay what it owes from them; or, with the position in the pool, add to it what the sources back beyond it at the
    /// anchor (after a failsafe draw). Returns the liquidity added, zero where the sources back none.
    function _place() internal returns (uint256 liquidity) {
        (uint128 placed, int24 lower, int24 upper) = position();
        bool full;
        bool held;
        if (placed == 0) {
            (full, lower, upper) = _range();
            held = !full && _holds(lower, upper);
        }
        PoolKey memory key = getPoolKey();
        // No more than the range's two ticks can still take, as OpenZeppelin holds a fresh position: inside 128 bits.
        liquidity = Math.min(
            _sized(key, lower, upper, full, held), Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing) - placed
        );
        if (liquidity == 0) return 0;
        _standing = Standing(placed + uint128(liquidity), lower, upper, placed == 0 && !full && !held && _asks());
        _modify(key, lower, upper, int256(liquidity));
    }

    /// @dev Inside an unlock: the whole position out with its fees, both coins into the sources, and its liquidity
    /// held on the swap floats that leaves for the next placing.
    function _remove() private {
        (uint128 liquidity, int24 lower, int24 upper) = position();
        delete _standing;
        _modify(getPoolKey(), lower, upper, -int256(uint256(liquidity)));
        _hold(liquidity, lower, upper);
    }

    /// @dev The liquidity a placing takes on [`lower`, `upper`], as the anchored hook sizes a swap's: OpenZeppelin's at
    /// the pool's price from what the sources offer, held on the anchored range to the position last taken out while
    /// it stands (`held`), and otherwise to what the sources back at the anchor.
    function _sized(PoolKey memory key, int24 lower, int24 upper, bool full, bool held)
        internal
        view
        returns (uint256 liquidity)
    {
        liquidity = ReHypothecationHook._getLiquidityToUse(lower, upper);
        if (full) return liquidity;
        if (held) return Math.min(liquidity, heldLiquidity);
        return _atAnchor(
            liquidity,
            lower,
            upper,
            _getMaxWithdrawFromYieldSource(key.currency0),
            _getMaxWithdrawFromYieldSource(key.currency1)
        );
    }

    /// @dev Inside an unlock: change the position's liquidity and settle both coins through the sources. The hook
    /// holds no other delta, so what the change leaves it owing or owed is the whole of it.
    function _modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidityDelta) private {
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidityDelta, bytes32(0)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
    }

    /// @dev Inside an unlock: a credit taken from the PoolManager and deposited into the coin's source, or a debt
    /// withdrawn from the source (which pays its depositor's debt there, and nothing else) and paid.
    function _settle(Currency currency, int256 amount) private {
        if (amount > 0) {
            poolManager.take(currency, address(this), uint256(amount));
            _depositToYieldSource(currency, uint256(amount));
        } else if (amount < 0) {
            _withdrawFromYieldSource(currency, uint256(-amount));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), uint256(-amount));
            poolManager.settle();
        }
    }
}

/// @notice The kit's standing hook: the anchored range of `AnchoredUnlockCheckedHook` as a position that stays in the
/// pool between keeper moves (`StandingPosition`). `test/StandingAnchoredHook.t.sol` proves a swap on it calls no
/// source, and `test/StandingRepeat.t.sol` holds it to the repeat-round property on gage's pegged and priced sources.
contract StandingAnchoredHook is StandingPosition {
    constructor(IPoolManager manager, address yieldSource0, address yieldSource1)
        UnlockCheckedHook(manager, yieldSource0, yieldSource1)
        AnchoredRange(yieldSource0, yieldSource1)
        StandingPosition(yieldSource0, yieldSource1)
    {}
}

/// @notice A standing position with the vault failsafe, asked as the anchored failsafe hook asks it
/// (`AnchoredFailsafeUnlockCheckedHook`): by price impact, of both sources. The first swap after a position was sized
/// afresh on the anchored range (a keeper move, in the ordinary run) reads what the position gives of the bought coin
/// before the pool's price has moved `DRAW_TOLERANCE_PIPS` (or reached the range's edge, where that is nearer). A swap
/// that needs more asks each source for the same share of what it backs, in the position and beside it, held to each
/// source's room (`failsafeLeft`) in step, the bought coin's source first and the other in proportion to what it gave;
/// what was drawn then tops the position up, at the anchor as a fresh position is sized, and stays in it. A swap its
/// own limit stops inside the tolerance asks nothing, nor one whose fee would not pay for the draw (`_pays`), and
/// neither calls a source. Whether it asked or not, that first swap is the only one that may: until the position is
/// sized afresh again no later swap asks, as on the anchored hook. A position on the full range (before both sources'
/// first move, past the band) never asks: a source has no room there. A position placed again at the liquidity it held
/// (after an LP move or a take-out) does not ask either.
abstract contract StandingFailsafe is StandingPosition {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev The most a swap may move the pool's price on the position the floats back before this hook asks the
    /// sources for more, in pips (millionths) of the price: 0.05%, the anchored failsafe hook's tolerance.
    uint24 internal constant DRAW_TOLERANCE_PIPS = 500;
    /// @dev The sqrt-price factors of that move, down and up, in Q96: sqrt(1 - 0.0005) and sqrt(1 + 0.0005).
    uint256 private constant TOLERANCE_DOWN_X96 = 79_208_352_997_136_529_422_885_942_753;
    uint256 private constant TOLERANCE_UP_X96 = 79_247_967_079_631_601_766_367_806_747;
    /// @dev The most `FORGONE_PIPS` may be: 1% of a draw.
    uint24 internal constant MAX_FORGONE_PIPS = 10_000;
    /// @dev A fee's denominator: pips, millionths.
    uint256 private constant PIPS = 1_000_000;

    /// @notice The least fee a draw must earn, in raw units of token0 when the swap's output is token0 and of token1
    /// when it is token1: what a draw costs in gas, its own and the keeper's sweep back, priced in that token.
    uint256 public immutable MIN_DRAW_FEE_0;
    uint256 public immutable MIN_DRAW_FEE_1;
    /// @notice The lending return a draw gives up until the keeper lends it again, in pips (millionths) of the ask.
    uint24 public immutable FORGONE_PIPS;

    error InvalidForgonePips(uint24 forgonePips);

    /// @param minDrawFee0 `MIN_DRAW_FEE_0`.
    /// @param minDrawFee1 `MIN_DRAW_FEE_1`.
    /// @param forgonePips `FORGONE_PIPS`, at most `MAX_FORGONE_PIPS`.
    constructor(uint256 minDrawFee0, uint256 minDrawFee1, uint24 forgonePips) {
        if (forgonePips > MAX_FORGONE_PIPS) revert InvalidForgonePips(forgonePips);
        (MIN_DRAW_FEE_0, MIN_DRAW_FEE_1, FORGONE_PIPS) = (minDrawFee0, minDrawFee1, forgonePips);
    }

    function _asks() internal pure override returns (bool) {
        return true;
    }

    /// @dev The ask of both sources before the first swap on a position sized afresh, at the fee the swap pays (`fee`
    /// with v4's override flag, or zero for the pool's own). Every step rounds the asks down and none can revert the
    /// swap: amounts are held to v4's 128 bits, and a source's refusal is caught (`_draw`).
    function _ask(PoolKey calldata key, SwapParams calldata params, uint24 fee) internal override {
        (uint160 p,,, uint24 poolFee) = poolManager.getSlot0(key.toId());
        (uint256 ask0, uint256 ask1) = _asked(key, params, p);
        if (ask0 == 0 || ask1 == 0) return;
        (address source0, address source1) = (SOURCE_0, SOURCE_1);
        // Held to each source's room, the other in step: a draw on one side alone deepens nothing.
        uint256 room = IGageRehypoSourceAnchor(source0).failsafeLeft();
        if (ask0 > room) (ask0, ask1) = (room, Math.mulDiv(ask1, room, ask0));
        room = IGageRehypoSourceAnchor(source1).failsafeLeft();
        if (ask1 > room) (ask0, ask1) = (Math.mulDiv(ask0, room, ask1), room);
        if (ask0 == 0 || ask1 == 0) return;
        // The bought coin's source first: what it gives sets the other's ask.
        bool down = params.zeroForOne;
        if (down) (source0, source1, ask0, ask1) = (source1, source0, ask1, ask0);
        if (!_pays(down, ask0, fee == 0 ? poolFee : fee & LPFeeLibrary.REMOVE_OVERRIDE_MASK)) return;
        uint256 got = _draw(source0, ask0);
        if (got == 0) return;
        ask1 = Math.mulDiv(ask1, got, ask0);
        if (ask1 != 0) _draw(source1, ask1);
        _place();
    }

    /// @dev What the swap asks of each source before their rooms: the same share of what each backs, in the position
    /// and beside it, `short / fills`, the share the position must deepen by (`_shortfall`). Zeros where the swap
    /// asks nothing, read from the PoolManager and this hook alone.
    function _asked(PoolKey calldata key, SwapParams calldata params, uint160 p)
        private
        view
        returns (uint256 ask0, uint256 ask1)
    {
        (uint128 liquidity, int24 lower, int24 upper) = position();
        (uint256 short, uint256 fills) = _shortfall(params, p, liquidity, lower, upper);
        if (short == 0) return (0, 0);
        (ask0, ask1) = _principal(p, liquidity, lower, upper);
        ask0 = _shareOf(ask0, key.currency0, short, fills);
        ask1 = _shareOf(ask1, key.currency1, short, fills);
    }

    /// @dev What the swap needs of the bought coin beyond what `liquidity` on [`lower`, `upper`] gives before the stop
    /// (`short`), and what it gives (`fills`); zeros where nothing is asked. The stop is the tolerance from the pool's
    /// price `p`, or the range's edge where it is nearer: a swap already there, or whose own limit stops it there or
    /// sooner, asks nothing. The liquidity gives token1 `L (sqrt p - sqrt e)` to a falling price and token0
    /// `L (1 / sqrt p - 1 / sqrt e)` to a rising one.
    function _shortfall(SwapParams calldata params, uint160 p, uint256 liquidity, int24 lower, int24 upper)
        private
        pure
        returns (uint256 short, uint256 fills)
    {
        uint256 stop;
        if (params.zeroForOne) {
            stop = Math.max(Math.mulDiv(p, TOLERANCE_DOWN_X96, FixedPoint96.Q96), TickMath.getSqrtPriceAtTick(lower));
            if (stop >= p || params.sqrtPriceLimitX96 >= stop) return (0, 0);
            fills = Math.mulDiv(liquidity, p - stop, FixedPoint96.Q96);
        } else {
            stop = Math.min(Math.mulDiv(p, TOLERANCE_UP_X96, FixedPoint96.Q96), TickMath.getSqrtPriceAtTick(upper));
            if (stop <= p || params.sqrtPriceLimitX96 <= stop) return (0, 0);
            fills = Math.mulDiv(Math.mulDiv(liquidity, FixedPoint96.Q96, p), stop - p, stop);
        }
        uint256 need = Math.min(_output(params, p), type(uint128).max);
        if (fills == 0 || need <= fills) return (0, 0);
        short = need - fills;
    }

    /// @dev `num / den` of what `currency`'s source backs for a swap now, `inPosition` of it in the pool and the rest
    /// what it still offers, rounded down.
    function _shareOf(uint256 inPosition, Currency currency, uint256 num, uint256 den) private view returns (uint256) {
        return Math.mulDiv(Math.min(inPosition + _getMaxWithdrawFromYieldSource(currency), type(uint128).max), num, den);
    }

    /// @dev What the swap takes of the output token at most, as `FailsafeUnlockCheckedHook._output` counts it: an
    /// exact-output swap's amount; an exact-input swap's input at the pool's price `p`, before the fee and the price's
    /// move, an input past v4's 128-bit amounts counted at that bound.
    function _output(SwapParams calldata params, uint160 p) private pure returns (uint256) {
        if (params.amountSpecified > 0) return uint256(params.amountSpecified);
        uint256 input;
        unchecked {
            input = uint256(-params.amountSpecified);
        }
        input = Math.min(input, type(uint128).max);
        return params.zeroForOne
            ? Math.mulDiv(Math.mulDiv(input, p, FixedPoint96.Q96), p, FixedPoint96.Q96)
            : Math.mulDiv(Math.mulDiv(input, FixedPoint96.Q96, p), FixedPoint96.Q96, p);
    }

    /// @dev Whether a draw of `ask` pays for itself, as `FailsafeUnlockCheckedHook._pays` judges it: the fee (`fee`, in
    /// pips) on half the ask covers the lending return the ask gives up (`FORGONE_PIPS` of it) and the draw's cost in
    /// gas in the output token (token1 for a swap from token0).
    function _pays(bool zeroForOne, uint256 ask, uint24 fee) private view returns (bool) {
        uint256 earns = Math.mulDiv(ask / 2, fee, PIPS);
        uint256 costs = Math.mulDiv(ask, FORGONE_PIPS, PIPS, Math.Rounding.Ceil);
        return earns >= costs + (zeroForOne ? MIN_DRAW_FEE_1 : MIN_DRAW_FEE_0);
    }

    /// @dev One source's draw. A refusal draws nothing (a source without the failsafe reverts the ask); an empty revert
    /// is out of gas and reverts the swap, so the gas a swapper sends cannot choose the float over the vault.
    function _draw(address source, uint256 ask) private returns (uint256 drawn) {
        try IGageRehypoSourceFailsafe(source).drawOnVault(ask) returns (uint256 got) {
            drawn = got;
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                assembly ("memory-safe") {
                    revert(0, 0)
                }
            }
        }
    }
}

/// @notice The kit's standing hook for a pool whose sources have the vault failsafe: `StandingAnchoredHook` with the ask
/// of both sources by price impact (`StandingFailsafe`), its draw economics set as the failsafe hook's are
/// (`MIN_DRAW_FEE_0`, `MIN_DRAW_FEE_1`, `FORGONE_PIPS`).
contract StandingAnchoredFailsafeHook is StandingFailsafe {
    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint256 minDrawFee0,
        uint256 minDrawFee1,
        uint24 forgonePips
    )
        UnlockCheckedHook(manager, yieldSource0, yieldSource1)
        AnchoredRange(yieldSource0, yieldSource1)
        StandingPosition(yieldSource0, yieldSource1)
        StandingFailsafe(minDrawFee0, minDrawFee1, forgonePips)
    {}
}
