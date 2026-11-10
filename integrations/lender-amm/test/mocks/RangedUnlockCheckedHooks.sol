// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {UnlockCheckedHook} from "../../src/UnlockCheckedHook.sol";
import {FailsafeUnlockCheckedHook} from "../../src/FailsafeUnlockCheckedHook.sol";

/// @notice The kit's reference hook (`UnlockCheckedHook`, OpenZeppelin's sizing unchanged) with its just-in-time range
/// chosen at deploy, standing in for a partner's narrow-range hook: mode 0 the full range, mode 1 fixed at
/// [lo, hi], mode 2 the pool's tick plus and minus `half`, re-centred at every swap. `setFee` sets a dynamic-fee
/// pool's LP fee, as a partner's fee logic would.
contract RangedUnlockCheckedHook is UnlockCheckedHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    uint8 public immutable MODE;
    int24 public immutable LO;
    int24 public immutable HI;
    int24 public immutable HALF;

    constructor(IPoolManager m, address s0, address s1, uint8 mode, int24 lo, int24 hi, int24 half)
        UnlockCheckedHook(m, s0, s1)
    {
        (MODE, LO, HI, HALF) = (mode, lo, hi, half);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(getPoolKey().toId());
    }

    function getTickLower() public view override returns (int24) {
        if (MODE == 1) return LO;
        if (MODE == 2) return _tick() - HALF;
        return super.getTickLower();
    }

    function getTickUpper() public view override returns (int24) {
        if (MODE == 1) return HI;
        if (MODE == 2) return _tick() + HALF;
        return super.getTickUpper();
    }

    function setFee(uint24 fee) external {
        poolManager.updateDynamicLPFee(getPoolKey(), fee);
    }
}

/// @notice The same ranges on the kit's failsafe hook (`FailsafeUnlockCheckedHook`, its ask unchanged).
contract RangedFailsafeUnlockCheckedHook is FailsafeUnlockCheckedHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    uint8 public immutable MODE;
    int24 public immutable LO;
    int24 public immutable HI;
    int24 public immutable HALF;

    constructor(IPoolManager m, address s0, address s1, uint8 mode, int24 lo, int24 hi, int24 half)
        FailsafeUnlockCheckedHook(m, s0, s1, 0, 0, 0)
    {
        (MODE, LO, HI, HALF) = (mode, lo, hi, half);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(getPoolKey().toId());
    }

    function getTickLower() public view override returns (int24) {
        if (MODE == 1) return LO;
        if (MODE == 2) return _tick() - HALF;
        return super.getTickLower();
    }

    function getTickUpper() public view override returns (int24) {
        if (MODE == 1) return HI;
        if (MODE == 2) return _tick() + HALF;
        return super.getTickUpper();
    }

    function setFee(uint24 fee) external {
        poolManager.updateDynamicLPFee(getPoolKey(), fee);
    }
}
