// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BoundedFee, ModuleFee} from "./AnchoredFeeHook.sol";
import {StandingAnchoredHook, StandingAnchoredFailsafeHook} from "./StandingAnchoredHook.sol";

/// @notice The kit's standing fee hook for a pool whose sources have no vault failsafe: `StandingAnchoredHook` on a v4
/// dynamic-fee pool, where the hook names each swap's fee as it starts. The fee is a fee module's quote for one of
/// its own pools and the swap's direction, inside the bounds fixed at deployment (`ModuleFee`, `BoundedFee`), as the
/// kit's anchored fee hooks name it (`AnchoredFeeHook`). The pool must be a dynamic-fee pool, or its key's fee would be
/// charged and the rule ignored. The fee is returned to the PoolManager as this swap's fee (`OVERRIDE_FEE_FLAG`): the
/// pool's stored fee is never set and never read. The module's quote is the one read a swap on a position in place
/// makes outside the PoolManager. `test/StandingFeeHook.t.sol` proves the rule and `test/StandingRepeat.t.sol` holds
/// the hook to the repeat-round property.
contract StandingAnchoredFeeHook is StandingAnchoredHook, ModuleFee {
    using LPFeeLibrary for uint24;

    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint24 feeFloor,
        uint24 feeCap,
        address feeModule,
        PoolId feePoolId
    )
        StandingAnchoredHook(manager, yieldSource0, yieldSource1)
        BoundedFee(feeFloor, feeCap)
        ModuleFee(feeModule, feePoolId)
    {}

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _swapFee(PoolKey calldata, SwapParams calldata params) internal view override returns (uint24) {
        return _bounded(_moduleFee(params.zeroForOne)) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}

/// @notice The kit's standing fee hook for a pool whose sources have the vault failsafe: `StandingAnchoredFailsafeHook`
/// on a dynamic-fee pool, with a fee module's quote as each swap's fee (as `StandingAnchoredFeeHook` names it), the fee
/// a draw is judged at (`_pays`).
contract StandingAnchoredFailsafeFeeHook is StandingAnchoredFailsafeHook, ModuleFee {
    using LPFeeLibrary for uint24;

    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint256 minDrawFee0,
        uint256 minDrawFee1,
        uint24 forgonePips,
        uint24 feeFloor,
        uint24 feeCap,
        address feeModule,
        PoolId feePoolId
    )
        StandingAnchoredFailsafeHook(manager, yieldSource0, yieldSource1, minDrawFee0, minDrawFee1, forgonePips)
        BoundedFee(feeFloor, feeCap)
        ModuleFee(feeModule, feePoolId)
    {}

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _swapFee(PoolKey calldata, SwapParams calldata params) internal view override returns (uint24) {
        return _bounded(_moduleFee(params.zeroForOne)) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
