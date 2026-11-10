// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ERC4626ReHypothecationHook} from "./ERC4626ReHypothecationHook.sol";

/// @notice OpenZeppelin's rehypothecation hook on ERC-4626 sources (`ERC4626ReHypothecationHook`) with the one rule a
/// partner adds (docs/rehypo-source.md): no LP move while the PoolManager is unlocked, so an LP cannot call it from an
/// unlock of its own. Swaps never call these functions. The reference a partner's hook starts from: the plug test
/// (`test/RehypoSourcePlug.t.sol`) proves it on gage's sources, and the set-up script (`script/RehypoSource.s.sol`)
/// deploys it.
contract UnlockCheckedHook is ERC4626ReHypothecationHook {
    using TransientStateLibrary for IPoolManager;

    error LiquidityChangeInsideUnlock();

    constructor(IPoolManager manager, address yieldSource0, address yieldSource1)
        ERC4626ReHypothecationHook(manager, yieldSource0, yieldSource1)
    {}

    function seedLiquidity(uint256 amount0, uint256 amount1)
        public
        payable
        virtual
        override
        returns (uint256 shares, BalanceDelta delta)
    {
        _requireLocked();
        return super.seedLiquidity(amount0, amount1);
    }

    function addReHypothecatedLiquidity(uint256 shares, uint256 amount0Max, uint256 amount1Max)
        public
        payable
        virtual
        override
        returns (BalanceDelta delta)
    {
        _requireLocked();
        return super.addReHypothecatedLiquidity(shares, amount0Max, amount1Max);
    }

    function removeReHypothecatedLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        public
        virtual
        override
        returns (BalanceDelta delta)
    {
        _requireLocked();
        return super.removeReHypothecatedLiquidity(shares, amount0Min, amount1Min);
    }

    function _requireLocked() internal view {
        if (poolManager.isUnlocked()) revert LiquidityChangeInsideUnlock();
    }
}
