// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ReHypothecationERC4626Mock} from "@openzeppelin/uniswap-hooks/src/mocks/general/ReHypothecationERC4626Mock.sol";

/// @notice OpenZeppelin's ERC-4626 rehypothecation hook with its just-in-time range narrowed, as a partner's own hook
/// might place it (a venue's ledger may be per range). Sizing is OpenZeppelin's own.
contract RangedReHypothecationMock is ReHypothecationERC4626Mock {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    bool internal immutable FOLLOWS;
    int24 internal immutable HALF;
    int24 internal immutable CENTRE;

    constructor(IPoolManager manager, address source0, address source1, bool follows, int24 half, int24 centre)
        ReHypothecationERC4626Mock(manager, source0, source1)
    {
        FOLLOWS = follows;
        HALF = half;
        CENTRE = centre;
    }

    function _centre() internal view returns (int24) {
        if (!FOLLOWS) return CENTRE;
        (, int24 tick,,) = poolManager.getSlot0(getPoolKey().toId());
        return tick;
    }

    function getTickLower() public view override returns (int24) {
        if (HALF == type(int24).max) return TickMath.MIN_TICK;
        return _centre() - HALF;
    }

    function getTickUpper() public view override returns (int24) {
        if (HALF == type(int24).max) return TickMath.MAX_TICK;
        return _centre() + HALF;
    }
}

/// @notice OpenZeppelin's ERC-4626 rehypothecation hook with a per-range ledger: each swap adds liquidity in several
/// fixed ranges, each sized by OpenZeppelin's own `_getLiquidityToUse` for that range at the moment it is added, so a
/// later range only sees the float the earlier ones left.
contract MultiRangeReHypothecationMock is ReHypothecationERC4626Mock {
    using SafeCast for uint256;

    int24[] internal lowers;
    int24[] internal uppers;
    uint128[] internal added;
    /// @dev 1 sizes each range from the full `maxWithdraw` (a ledger that does not net the float across ranges);
    /// n sizes each range at 1/n of it (a ledger that nets).
    uint256 internal immutable SPLIT;

    constructor(
        IPoolManager manager_,
        address source0,
        address source1,
        int24[] memory los,
        int24[] memory his,
        uint256 split
    ) ReHypothecationERC4626Mock(manager_, source0, source1) {
        lowers = los;
        uppers = his;
        SPLIT = split;
        for (uint256 i; i < los.length; ++i) {
            added.push(0);
        }
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        for (uint256 i; i < lowers.length; ++i) {
            uint256 liquidity = _getLiquidityToUse(lowers[i], uppers[i]) / SPLIT;
            if (liquidity == 0) continue;
            poolManager.modifyLiquidity(
                getPoolKey(),
                ModifyLiquidityParams({
                    tickLower: lowers[i], tickUpper: uppers[i], liquidityDelta: liquidity.toInt256(), salt: bytes32(0)
                }),
                ""
            );
            added[i] = uint128(liquidity);
        }
        if (_total() == 0) revert NoUsableLiquidity();
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        for (uint256 i; i < lowers.length; ++i) {
            if (added[i] == 0) continue;
            poolManager.modifyLiquidity(
                getPoolKey(),
                ModifyLiquidityParams({
                    tickLower: lowers[i],
                    tickUpper: uppers[i],
                    liquidityDelta: -int256(uint256(added[i])),
                    salt: bytes32(0)
                }),
                ""
            );
            added[i] = 0;
        }
        _resolveHookDelta(key.currency0);
        _resolveHookDelta(key.currency1);
        return (this.afterSwap.selector, 0);
    }

    function _total() internal view returns (uint256 sum) {
        for (uint256 i; i < added.length; ++i) {
            sum += added[i];
        }
    }
}

interface IGageRehypoSourceFailsafe {
    function drawOnVault(uint256 assets) external returns (uint256 drawn);
}

/// @notice OpenZeppelin's ERC-4626 rehypothecation hook, full range, with the vault failsafe (2.5) as a partner hook
/// might use it: before an exact-output swap that would take more than half of what the output side's source backs, it
/// asks that source for the shortfall that keeps the swap within half, then sizes its just-in-time liquidity as
/// OpenZeppelin does. A smaller swap asks nothing.
contract FailsafeReHypothecationMock is ReHypothecationERC4626Mock {
    constructor(IPoolManager manager_, address source0, address source1)
        ReHypothecationERC4626Mock(manager_, source0, source1)
    {}

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) {
            address out = getCurrencyYieldSource(params.zeroForOne ? key.currency1 : key.currency0);
            uint256 need = uint256(params.amountSpecified);
            uint256 most = IERC4626(out).maxWithdraw(address(this));
            if (need * 2 > most) IGageRehypoSourceFailsafe(out).drawOnVault(need * 2 - most);
        }
        return super._beforeSwap(sender, key, params, hookData);
    }
}
