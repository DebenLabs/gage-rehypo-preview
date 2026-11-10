// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {UnlockCheckedHook} from "./UnlockCheckedHook.sol";
import {FailsafeUnlockCheckedHook, IGageRehypoSourceFailsafe} from "./FailsafeUnlockCheckedHook.sol";

/// @notice What an anchored range reads on a gage rehypo source: its getters, nothing added for the hook.
interface IGageRehypoSourceAnchor {
    function RANGE_TICKS() external view returns (uint24);
    function PRICED_TOKEN() external view returns (address);
    function centre() external view returns (uint160);
    function centreAt() external view returns (uint40);
    function swapCap() external view returns (uint256);
    function swapFloat() external view returns (uint256);
    function failsafeLeft() external view returns (uint256);
}

/// @notice The just-in-time range a declared narrower source supports (docs/rehypo-source.md, item 6): fixed on the
/// sources' anchor between keeper moves, never following the pool's price. The anchor is parity on a stable pair (one
/// whole token for one, from the two tokens' decimals) and, on a priced pair, the band centre of the priced source
/// centred last (`centre`, which only its keeper's `rebalanceAt` moves, inside no unlock). The range is the sources'
/// declared width (`RANGE_TICKS`, the wider of the two) around the anchor, widened outward to the pool's tick spacing.
/// The full range when either source declares it, where the range would not fit the pool's usable ticks, and while
/// either source has no cap from a keeper move inside the band (`swapCap` zero): before its first keeper move, whatever
/// it was seeded with, and past the band, where the full range is the wider shape. Its liquidity is sized at the anchor
/// at the first swap after a keeper move: never more than the sources back there, so, as in a position fixed between
/// keeper moves, it grows no deeper away from the anchor. OpenZeppelin's sizing alone takes the swap's start price,
/// where one side stops binding near either edge: a push through the thin liquidity at the centre would then be traded
/// back in steps through deeper liquidity near the edge. Until the next keeper move the position then stays as that
/// swap left it: each swap uses the liquidity the last one used, scaled by the LP moves since, never more than what the
/// sources offer at the swap's price, so a swap that crosses the range leaves the trade back open. Sizing every swap
/// at the anchor again would size it on the side that swap emptied, and freeze the pool both ways until the keeper's
/// next move. A change to either source's swap float that this hook did not make (a keeper move) sizes afresh.
abstract contract AnchoredRange {
    IGageRehypoSourceAnchor private immutable ANCHOR_SOURCE_0;
    IGageRehypoSourceAnchor private immutable ANCHOR_SOURCE_1;
    /// @notice The range's width in ticks before the tick spacing widens it; zero for the full range.
    uint24 public immutable RANGE_WIDTH;
    bool private immutable PRICED_0;
    bool private immutable PRICED_1;
    /// @notice A stable pair's anchor: one whole token0 for one whole token1, as a v4 sqrt price, and its tick. Zero on
    /// a priced pair.
    uint160 public immutable PARITY_SQRT_PRICE;
    int24 public immutable PARITY_TICK;

    /// @notice The just-in-time liquidity the position holds between swaps: what the last swap used, scaled by the LP
    /// moves since. Zero before the first swap and after every share has left.
    uint128 public heldLiquidity;
    /// @dev The range and both sources' swap floats when `heldLiquidity` was set, hashed: while they are unchanged,
    /// only this hook's own swaps and LP moves have moved the sources since.
    bytes16 private _heldMark;

    constructor(address source0, address source1) {
        (ANCHOR_SOURCE_0, ANCHOR_SOURCE_1) = (IGageRehypoSourceAnchor(source0), IGageRehypoSourceAnchor(source1));
        uint24 r0 = ANCHOR_SOURCE_0.RANGE_TICKS();
        uint24 r1 = ANCHOR_SOURCE_1.RANGE_TICKS();
        RANGE_WIDTH = r0 == 0 || r1 == 0 ? 0 : (r0 > r1 ? r0 : r1);
        PRICED_0 = ANCHOR_SOURCE_0.PRICED_TOKEN() != address(0);
        PRICED_1 = ANCHOR_SOURCE_1.PRICED_TOKEN() != address(0);
        if (!PRICED_0 && !PRICED_1) {
            uint256 d0 = IERC20Metadata(IERC4626(source0).asset()).decimals();
            uint256 d1 = IERC20Metadata(IERC4626(source1).asset()).decimals();
            // Raw units of token1 per raw unit of token0 at one for one, as a v4 sqrt price.
            uint256 sqrtPrice = d1 >= d0
                ? Math.sqrt(Math.mulDiv(10 ** (d1 - d0), 1 << 192, 1))
                : Math.sqrt(Math.mulDiv(1, 1 << 192, 10 ** (d0 - d1)));
            PARITY_SQRT_PRICE = SafeCast.toUint160(sqrtPrice);
            PARITY_TICK = TickMath.getTickAtSqrtPrice(PARITY_SQRT_PRICE);
        }
    }

    /// @notice The anchor now, as a v4 sqrt price; `set` false before a priced pair's first centre.
    function anchorSqrtPrice() public view returns (bool set, uint160 sqrtPriceX96) {
        if (!PRICED_0 && !PRICED_1) return (true, PARITY_SQRT_PRICE);
        uint40 at;
        if (PRICED_0) (sqrtPriceX96, at) = (ANCHOR_SOURCE_0.centre(), ANCHOR_SOURCE_0.centreAt());
        if (PRICED_1) {
            uint40 at1 = ANCHOR_SOURCE_1.centreAt();
            if (at1 > at || sqrtPriceX96 == 0) sqrtPriceX96 = ANCHOR_SOURCE_1.centre();
        }
        return (sqrtPriceX96 != 0, sqrtPriceX96);
    }

    /// @notice The anchor's tick now; `set` false before a priced pair's first centre.
    function anchorTick() public view returns (bool set, int24 tick) {
        uint160 sqrtPriceX96;
        (set, sqrtPriceX96) = anchorSqrtPrice();
        if (set) tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Whether both sources hold a cap from a keeper move inside the band (`swapCap` non-zero): until then, and
    /// past the band, the range is the full range.
    function capped() public view returns (bool) {
        return ANCHOR_SOURCE_0.swapCap() != 0 && ANCHOR_SOURCE_1.swapCap() != 0;
    }

    /// @dev The liquidity a swap uses on the anchored range [`lower`, `upper`]: `liquidity` (OpenZeppelin's, at the
    /// swap's price, from what the sources offer now) held to the position the last swap left while it stands
    /// (`_holds`), and otherwise to what `amount0` and `amount1` back at the anchor (`_atAnchor`).
    function _anchoredLiquidity(uint256 liquidity, int24 lower, int24 upper, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        if (_holds(lower, upper)) return Math.min(liquidity, heldLiquidity);
        return _atAnchor(liquidity, lower, upper, amount0, amount1);
    }

    /// @dev `liquidity` (what OpenZeppelin sizes at the swap's start price) held to what `amount0` and `amount1` back at
    /// the anchor over [`lower`, `upper`]: token0 above the anchor, token1 below it.
    function _atAnchor(uint256 liquidity, int24 lower, int24 upper, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        (bool set, uint160 a) = anchorSqrtPrice();
        if (!set) return liquidity;
        uint160 l = TickMath.getSqrtPriceAtTick(lower);
        uint160 u = TickMath.getSqrtPriceAtTick(upper);
        if (a < l) a = l;
        if (a > u) a = u;
        if (a < u) liquidity = Math.min(liquidity, Math.mulDiv(amount0, Math.mulDiv(a, u, FixedPoint96.Q96), u - a));
        if (a > l) liquidity = Math.min(liquidity, Math.mulDiv(amount1, FixedPoint96.Q96, a - l));
        return liquidity;
    }

    /// @dev Whether the position the last swap left still stands on [`lower`, `upper`]: some liquidity held, the same
    /// range, and neither source's swap float moved by anything but this hook since.
    function _holds(int24 lower, int24 upper) internal view returns (bool) {
        return heldLiquidity != 0 && _heldMark == _mark(lower, upper);
    }

    /// @dev Hold `liquidity` on [`lower`, `upper`] from the sources' swap floats as they are now.
    function _hold(uint256 liquidity, int24 lower, int24 upper) internal {
        (heldLiquidity, _heldMark) = (SafeCast.toUint128(liquidity), _mark(lower, upper));
    }

    /// @dev After an LP move that took the share supply from `supplyBefore` to `supplyAfter`: the position held before
    /// it, if it stood (`held`), scaled with the supply, as the sources scale their swap floats with the backing.
    function _rescale(bool held, uint256 supplyBefore, uint256 supplyAfter, int24 lower, int24 upper) internal {
        if (held) _hold(Math.mulDiv(heldLiquidity, supplyAfter, supplyBefore), lower, upper);
    }

    function _mark(int24 lower, int24 upper) private view returns (bytes16) {
        return bytes16(keccak256(abi.encode(lower, upper, ANCHOR_SOURCE_0.swapFloat(), ANCHOR_SOURCE_1.swapFloat())));
    }

    /// @dev The anchored range for a pool of `spacing`, or `full` for the full range.
    function _anchoredRange(int24 spacing) internal view returns (bool full, int24 lower, int24 upper) {
        uint24 width = RANGE_WIDTH;
        if (width == 0 || !capped()) return (true, 0, 0);
        (bool set, int24 anchor) = anchorTick();
        if (!set) return (true, 0, 0);
        int256 half = int256(uint256(width / 2));
        int256 lo = _floor(int256(anchor) - half, spacing);
        int256 hi = _ceil(int256(anchor) - half + int256(uint256(width)), spacing);
        if (lo < TickMath.minUsableTick(spacing) || hi > TickMath.maxUsableTick(spacing)) return (true, 0, 0);
        return (false, SafeCast.toInt24(lo), SafeCast.toInt24(hi));
    }

    function _floor(int256 tick, int24 spacing) private pure returns (int256) {
        int256 s = spacing;
        int256 q = tick / s;
        if (tick % s != 0 && tick < 0) --q;
        return q * s;
    }

    function _ceil(int256 tick, int24 spacing) private pure returns (int256) {
        int256 s = spacing;
        int256 q = tick / s;
        if (tick % s != 0 && tick > 0) ++q;
        return q * s;
    }
}

/// @notice The kit's reference hook (`UnlockCheckedHook`) with its just-in-time range anchored (`AnchoredRange`): the
/// reference for sources declared narrower than the full range. `test/RehypoSourceRepeat.t.sol` holds it to the
/// repeat-round property on gage's sources, `test/AnchoredUnlockCheckedHook.t.sol` to a trade back that always fills
/// between keeper moves, and `script/RehypoSource.s.sol` deploys it for a pool whose two sources declare a range.
contract AnchoredUnlockCheckedHook is UnlockCheckedHook, AnchoredRange {
    constructor(IPoolManager manager, address yieldSource0, address yieldSource1)
        UnlockCheckedHook(manager, yieldSource0, yieldSource1)
        AnchoredRange(yieldSource0, yieldSource1)
    {}

    function getTickLower() public view override returns (int24) {
        (bool full, int24 lower,) = _anchoredRange(getPoolKey().tickSpacing);
        return full ? super.getTickLower() : lower;
    }

    function getTickUpper() public view override returns (int24) {
        (bool full,, int24 upper) = _anchoredRange(getPoolKey().tickSpacing);
        return full ? super.getTickUpper() : upper;
    }

    function addReHypothecatedLiquidity(uint256 shares, uint256 amount0Max, uint256 amount1Max)
        public
        payable
        override
        returns (BalanceDelta delta)
    {
        (int24 lower, int24 upper) = (getTickLower(), getTickUpper());
        (bool held, uint256 supply) = (_holds(lower, upper), totalSupply());
        delta = super.addReHypothecatedLiquidity(shares, amount0Max, amount1Max);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    function removeReHypothecatedLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        public
        override
        returns (BalanceDelta delta)
    {
        (int24 lower, int24 upper) = (getTickLower(), getTickUpper());
        (bool held, uint256 supply) = (_holds(lower, upper), totalSupply());
        delta = super.removeReHypothecatedLiquidity(shares, amount0Min, amount1Min);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    function _getLiquidityToUse(int24 tickLower, int24 tickUpper) internal view override returns (uint256) {
        uint256 liquidity = super._getLiquidityToUse(tickLower, tickUpper);
        PoolKey memory key = getPoolKey();
        (bool full,,) = _anchoredRange(key.tickSpacing);
        if (full) return liquidity;
        return _anchoredLiquidity(
            liquidity,
            tickLower,
            tickUpper,
            _getMaxWithdrawFromYieldSource(key.currency0),
            _getMaxWithdrawFromYieldSource(key.currency1)
        );
    }

    /// @dev Holds the liquidity the swap used, on the sources' swap floats after it.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, int128 hookDelta) {
        uint256 used = _getHookPositionLiquidity();
        (selector, hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        _hold(used, getTickLower(), getTickUpper());
    }
}

/// @notice The same anchored range on the kit's failsafe hook (`FailsafeUnlockCheckedHook`), with the ask an anchored
/// range needs. Its liquidity is what BOTH sources back at the anchor, so the cash one coin keeps free deepens nothing
/// alone, and a swap fills badly long before it takes half of the coin it buys: wherever the pool's price rests off
/// the anchor, one side backs little. So this hook asks by price impact, and asks both sources. Before a swap that
/// sizes the position afresh, it reads what the liquidity it would use gives of the bought coin before the pool's
/// price has moved `DRAW_TOLERANCE_PIPS` (or reached the range's edge, where that is nearer). A swap that needs more
/// asks each source for the same share of what it backs, the share that lets the swap fill inside the tolerance, held
/// to each source's room (`failsafeLeft`) in step, so the position deepens by that share. The bought coin's source
/// answers first and the other is asked in proportion to what it gave. A swap whose own price limit stops it inside
/// the tolerance asks nothing, however much it names, and so does one whose fee would not pay for the draw (`_pays`,
/// on the bought coin's ask). The sources decide what they give: nothing outside the band of their last keeper move,
/// at most `FAILSAFE_BPS` of the backing between two moves, from the vault's free cash or, with no vault, from the
/// float the source keeps closed. A source without the failsafe has no room, and then neither is asked. Between
/// keeper moves the position stands as the last swap left it and a draw could not deepen it, so no later swap asks.
/// While the range is the full range (before both sources' first move, past the band) no swap asks: a source has no
/// room there.
contract AnchoredFailsafeUnlockCheckedHook is FailsafeUnlockCheckedHook, AnchoredRange {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The most a swap may move the pool's price on the liquidity the floats back before this hook asks the
    /// sources for more, in pips (millionths) of the price: 0.05%.
    uint24 public constant DRAW_TOLERANCE_PIPS = 500;
    /// @dev The sqrt-price factors of that move, down and up, in Q96: sqrt(1 - 0.0005) and sqrt(1 + 0.0005).
    uint256 private constant TOLERANCE_DOWN_X96 = 79_208_352_997_136_529_422_885_942_753;
    uint256 private constant TOLERANCE_UP_X96 = 79_247_967_079_631_601_766_367_806_747;

    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint256 minDrawFee0,
        uint256 minDrawFee1,
        uint24 forgonePips
    )
        FailsafeUnlockCheckedHook(manager, yieldSource0, yieldSource1, minDrawFee0, minDrawFee1, forgonePips)
        AnchoredRange(yieldSource0, yieldSource1)
    {}

    function getTickLower() public view override returns (int24) {
        (bool full, int24 lower,) = _anchoredRange(getPoolKey().tickSpacing);
        return full ? super.getTickLower() : lower;
    }

    function getTickUpper() public view override returns (int24) {
        (bool full,, int24 upper) = _anchoredRange(getPoolKey().tickSpacing);
        return full ? super.getTickUpper() : upper;
    }

    function addReHypothecatedLiquidity(uint256 shares, uint256 amount0Max, uint256 amount1Max)
        public
        payable
        override
        returns (BalanceDelta delta)
    {
        (int24 lower, int24 upper) = (getTickLower(), getTickUpper());
        (bool held, uint256 supply) = (_holds(lower, upper), totalSupply());
        delta = super.addReHypothecatedLiquidity(shares, amount0Max, amount1Max);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    function removeReHypothecatedLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        public
        override
        returns (BalanceDelta delta)
    {
        (int24 lower, int24 upper) = (getTickLower(), getTickUpper());
        (bool held, uint256 supply) = (_holds(lower, upper), totalSupply());
        delta = super.removeReHypothecatedLiquidity(shares, amount0Min, amount1Min);
        _rescale(held, supply, totalSupply(), lower, upper);
    }

    function _askFailsafe(PoolKey calldata key, SwapParams calldata params) internal virtual override {
        (uint160 p,,, uint24 fee) = poolManager.getSlot0(key.toId());
        _askBoth(key, params, p, fee);
    }

    /// @dev The ask of both sources before a swap at the pool's price `p` and the fee `fee` it pays: only on the
    /// anchored range, and only where the swap sizes the position afresh (`_shortfall`). Every step rounds the asks
    /// down and none can revert the swap: amounts are held to v4's 128 bits, and a source's refusal is caught (`_draw`).
    function _askBoth(PoolKey calldata key, SwapParams calldata params, uint160 p, uint24 fee) internal {
        (uint256 short, uint256 fills) = _shortfall(key, params, p);
        if (short == 0) return;
        // The same share of what each source backs: `short / fills`, the share the position must deepen by.
        uint256 ask0 = _shareOf(key.currency0, short, fills);
        uint256 ask1 = _shareOf(key.currency1, short, fills);
        address source0 = getCurrencyYieldSource(key.currency0);
        address source1 = getCurrencyYieldSource(key.currency1);
        // Held to each source's room, the other in step: a draw on one side alone deepens nothing.
        uint256 room = IGageRehypoSourceAnchor(source0).failsafeLeft();
        if (ask0 > room) (ask0, ask1) = (room, Math.mulDiv(ask1, room, ask0));
        room = IGageRehypoSourceAnchor(source1).failsafeLeft();
        if (ask1 > room) (ask0, ask1) = (Math.mulDiv(ask0, room, ask1), room);
        if (ask0 == 0 || ask1 == 0) return;
        bool down = params.zeroForOne;
        if (!_pays(down, down ? ask1 : ask0, fee)) return;
        // The bought coin's source first: what it gives sets the other's ask.
        if (down) {
            uint256 got = _draw(source1, ask1);
            if (got != 0) _draw(source0, Math.mulDiv(ask0, got, ask1));
        } else {
            uint256 got = _draw(source0, ask0);
            if (got != 0) _draw(source1, Math.mulDiv(ask1, got, ask0));
        }
    }

    /// @dev What the swap needs of the bought coin beyond what the liquidity it would use gives before the stop
    /// (`short`), and what that liquidity gives (`fills`); zeros where nothing is asked. The stop is the tolerance from
    /// the pool's price `p`, or the range's edge where it is nearer: a swap already there, or whose own limit stops it
    /// there or sooner, asks nothing. The liquidity gives token1 `L (sqrt p - sqrt e)` to a falling price and token0
    /// `L (1 / sqrt p - 1 / sqrt e)` to a rising one.
    function _shortfall(PoolKey calldata key, SwapParams calldata params, uint160 p)
        private
        view
        returns (uint256 short, uint256 fills)
    {
        (bool full, int24 lower, int24 upper) = _anchoredRange(key.tickSpacing);
        if (full || _holds(lower, upper)) return (0, 0);
        uint256 stop;
        if (params.zeroForOne) {
            stop = Math.max(Math.mulDiv(p, TOLERANCE_DOWN_X96, FixedPoint96.Q96), TickMath.getSqrtPriceAtTick(lower));
            if (stop >= p || params.sqrtPriceLimitX96 >= stop) return (0, 0);
            fills = Math.mulDiv(_getLiquidityToUse(lower, upper), p - stop, FixedPoint96.Q96);
        } else {
            stop = Math.min(Math.mulDiv(p, TOLERANCE_UP_X96, FixedPoint96.Q96), TickMath.getSqrtPriceAtTick(upper));
            if (stop <= p || params.sqrtPriceLimitX96 <= stop) return (0, 0);
            fills = Math.mulDiv(Math.mulDiv(_getLiquidityToUse(lower, upper), FixedPoint96.Q96, p), stop - p, stop);
        }
        uint256 need = Math.min(_output(params, p), type(uint128).max);
        if (fills == 0 || need <= fills) return (0, 0);
        short = need - fills;
    }

    /// @dev `num / den` of what `currency`'s source backs for a swap now, rounded down.
    function _shareOf(Currency currency, uint256 num, uint256 den) private view returns (uint256) {
        return Math.mulDiv(Math.min(_getMaxWithdrawFromYieldSource(currency), type(uint128).max), num, den);
    }

    /// @dev One source's draw. A refusal draws nothing (a source without the failsafe reverts the ask); an empty revert
    /// is out of gas and reverts the swap, so the gas a swapper sends cannot choose the float over the vault.
    function _draw(address source, uint256 ask) private returns (uint256 drawn) {
        if (ask == 0) return 0;
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

    function _getLiquidityToUse(int24 tickLower, int24 tickUpper) internal view override returns (uint256) {
        uint256 liquidity = super._getLiquidityToUse(tickLower, tickUpper);
        PoolKey memory key = getPoolKey();
        (bool full,,) = _anchoredRange(key.tickSpacing);
        if (full) return liquidity;
        return _anchoredLiquidity(
            liquidity,
            tickLower,
            tickUpper,
            _getMaxWithdrawFromYieldSource(key.currency0),
            _getMaxWithdrawFromYieldSource(key.currency1)
        );
    }

    /// @dev Holds the liquidity the swap used, on the sources' swap floats after it.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, int128 hookDelta) {
        uint256 used = _getHookPositionLiquidity();
        (selector, hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        _hold(used, getTickLower(), getTickUpper());
    }
}
