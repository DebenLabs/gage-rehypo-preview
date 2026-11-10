// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {UnlockCheckedHook} from "./UnlockCheckedHook.sol";

/// @notice What a hook calls on a source with the vault failsafe (`GageRehypoSource.drawOnVault`, design 2.5).
interface IGageRehypoSourceFailsafe {
    function drawOnVault(uint256 assets) external returns (uint256 drawn);
}

/// @notice The reference hook (`UnlockCheckedHook`) with the vault failsafe (design 2.5) as a partner's hook uses it: the
/// vault's free cash as extra float when the float is not enough, only where it pays. Before a swap that could take
/// more than half of what the output side's source backs, it asks that source for the shortfall that keeps the swap
/// within half, then sizes its just-in-time liquidity as OpenZeppelin does. An exact-output swap names its output; an
/// exact-input one's is its input at the pool's price, before the fee and the price's move, so never less than the swap
/// takes. A swap can take more than half only if it needs more than half and its price limit lets it run more than half
/// way through what the position holds of the output token at the pool's price: a swap stopped at or next to the price
/// asks nothing, however much it names, so it cannot move the vault's cash into the float for a dust fill. A smaller
/// swap asks nothing, so a swap the float can fill never reaches the vault. Nor does one whose fee would not pay for the
/// draw: the pool's fee on what the swap needs beyond half of what the side backs must cover the lending return the
/// draw gives up until the keeper lends it again (`FORGONE_PIPS` of the ask) and the draw's own cost in gas, the
/// draw's and the keeper's sweep back (`MIN_DRAW_FEE_0` or `MIN_DRAW_FEE_1`, in the output token); otherwise the swap
/// fills on the float alone. The source decides what it gives: nothing outside the band of its last rebalance, at most
/// its `FAILSAFE_BPS` of the backing between two keeper moves, and only from its vault's free cash; a refusal leaves the
/// swap as it would have been. A source without the failsafe refuses the ask by reverting; the hook catches that and
/// the swap goes on unchanged. An empty revert (the source rethrows its vault running out of gas) is not caught: it
/// reverts the swap, so the gas a swapper sends cannot choose the float over the vault.
/// `test/FailsafeUnlockCheckedHook.t.sol` proves it on gage's sources, and `script/RehypoSource.s.sol` deploys it for a
/// pool whose lent source has the failsafe.
contract FailsafeUnlockCheckedHook is UnlockCheckedHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The most `FORGONE_PIPS` may be: 1% of a draw.
    uint24 public constant MAX_FORGONE_PIPS = 10_000;
    /// @dev A fee's denominator: pips, millionths.
    uint256 internal constant PIPS = 1_000_000;

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
    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint256 minDrawFee0,
        uint256 minDrawFee1,
        uint24 forgonePips
    ) UnlockCheckedHook(manager, yieldSource0, yieldSource1) {
        if (forgonePips > MAX_FORGONE_PIPS) revert InvalidForgonePips(forgonePips);
        (MIN_DRAW_FEE_0, MIN_DRAW_FEE_1, FORGONE_PIPS) = (minDrawFee0, minDrawFee1, forgonePips);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _askFailsafe(key, params);
        return super._beforeSwap(sender, key, params, hookData);
    }

    /// @dev The ask before a swap: the shortfall that keeps it within half of what the output side's source backs, only
    /// when it needs more than half, its limit lets it take more than half (`_takesPastHalf`) and its fee pays for the
    /// draw (`_pays`).
    function _askFailsafe(PoolKey calldata key, SwapParams calldata params) internal virtual {
        address out = getCurrencyYieldSource(params.zeroForOne ? key.currency1 : key.currency0);
        uint256 most = IERC4626(out).maxWithdraw(address(this));
        // An exact-output swap the float can fill within half reads nothing more.
        if (params.amountSpecified > 0 && uint256(params.amountSpecified) * 2 <= most) return;
        (uint160 p,,, uint24 fee) = poolManager.getSlot0(key.toId());
        uint256 need = _output(params, p);
        if (need * 2 <= most || !_takesPastHalf(params, p)) return;
        uint256 ask = need * 2 - most;
        if (!_pays(params.zeroForOne, ask, fee)) return;
        // A source without the failsafe (a float-only side, or any created with none) reverts the ask: the swap then
        // goes on as it would have without one. An empty revert is out of gas, and reverts the swap.
        try IGageRehypoSourceFailsafe(out).drawOnVault(ask) {}
        catch (bytes memory reason) {
            if (reason.length == 0) {
                assembly ("memory-safe") {
                    revert(0, 0)
                }
            }
        }
    }

    /// @dev What the swap takes of the output token at most: an exact-output swap's amount; an exact-input swap's input
    /// at the pool's price `p` (token1 per token0, a v4 sqrt price), before the fee and the price's move, an input past
    /// v4's 128-bit amounts counted at that bound.
    function _output(SwapParams calldata params, uint160 p) internal pure returns (uint256) {
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

    /// @dev Whether a draw of `ask` pays for itself: the pool's fee (`fee`, in pips) on what the swap needs beyond half
    /// of what the side backs, half the ask, covers the lending return the ask gives up (`FORGONE_PIPS` of it) and the
    /// draw's cost in gas in the output token (token1 for a swap from token0).
    function _pays(bool zeroForOne, uint256 ask, uint24 fee) internal view returns (bool) {
        uint256 earns = Math.mulDiv(ask / 2, fee, PIPS);
        uint256 costs = Math.mulDiv(ask, FORGONE_PIPS, PIPS, Math.Rounding.Ceil);
        return earns >= costs + (zeroForOne ? MIN_DRAW_FEE_1 : MIN_DRAW_FEE_0);
    }

    /// @dev Whether the swap's price limit lets it take more than half of what the position holds of the output token
    /// at the pool's price `p`, on the range the swap will use (`getTickLower`, `getTickUpper`). With the position's
    /// liquidity `L`, a falling price `p` holds `L (sqrt p - sqrt l)` of token1 and a swap to `e` (its limit, or the
    /// range's lower edge) takes `L (sqrt p - sqrt e)`; a rising one holds `L (1 / sqrt p - 1 / sqrt u)` of token0 and
    /// takes `L (1 / sqrt p - 1 / sqrt e)`. Whatever the source gives, the swap then takes at most that share of it.
    function _takesPastHalf(SwapParams calldata params, uint160 p) internal view returns (bool) {
        uint160 l = TickMath.getSqrtPriceAtTick(getTickLower());
        uint160 u = TickMath.getSqrtPriceAtTick(getTickUpper());
        uint160 limit = params.sqrtPriceLimitX96;
        if (params.zeroForOne) {
            uint160 down = limit > l ? limit : l;
            if (p <= down) return false;
            return 2 * uint256(p - down) > uint256(p - l);
        }
        uint160 up = limit < u ? limit : u;
        if (p >= up) return false;
        // 2 (1 / sqrt p - 1 / sqrt e) > 1 / sqrt p - 1 / sqrt u, times sqrt p sqrt e sqrt u: 2 (e - p) u > (u - p) e.
        return 2 * uint256(up - p) > Math.mulDiv(u - p, up, u, Math.Rounding.Ceil);
    }
}
