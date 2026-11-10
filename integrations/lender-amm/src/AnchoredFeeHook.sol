// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IGageRehypoSourceFailsafe} from "./FailsafeUnlockCheckedHook.sol";
import {AnchoredUnlockCheckedHook, AnchoredFailsafeUnlockCheckedHook} from "./AnchoredUnlockCheckedHook.sol";

/// @notice What a fee hook reads for a swap's fee (`ModuleFee`): the fee, in pips (millionths), a module quotes now for
/// pool `id` and a swap's direction. A view, called with a fixed amount of gas; zero, a revert or a malformed answer
/// reads as no answer.
interface IRehypoFeeSource {
    function currentFee(PoolId id, bool zeroForOne) external view returns (uint24);
}

/// @notice The bounds every swap fee on the kit's fee hooks is held between, fixed at deployment: whatever a hook's fee
/// rule answers, a swap pays at least `FEE_FLOOR` and at most `FEE_CAP`, and no answer (zero) pays the floor, so a swap
/// is never free and never refused for its fee. The floor is what the sources' repeat-round proof is run at.
abstract contract BoundedFee {
    /// @notice The least `FEE_FLOOR` may be, in pips: 0.01%, the lowest fee the kit's repeat-round proof covers.
    uint24 public constant MIN_FEE_FLOOR = 100;
    /// @notice The most `FEE_CAP` may be, in pips: 5%.
    uint24 public constant MAX_FEE_CAP = 50_000;

    /// @notice The least a swap pays, in pips, and what it pays when the rule gives no answer.
    uint24 public immutable FEE_FLOOR;
    /// @notice The most a swap pays, in pips.
    uint24 public immutable FEE_CAP;

    error InvalidFeeBounds(uint24 feeFloor, uint24 feeCap);
    error NotDynamicFee();

    /// @param feeFloor `FEE_FLOOR`, from `MIN_FEE_FLOOR`.
    /// @param feeCap `FEE_CAP`, from `feeFloor` to `MAX_FEE_CAP`.
    constructor(uint24 feeFloor, uint24 feeCap) {
        if (feeFloor < MIN_FEE_FLOOR || feeCap < feeFloor || feeCap > MAX_FEE_CAP) {
            revert InvalidFeeBounds(feeFloor, feeCap);
        }
        (FEE_FLOOR, FEE_CAP) = (feeFloor, feeCap);
    }

    /// @dev `fee` held between `FEE_FLOOR` and `FEE_CAP`; zero, no answer, is the floor.
    function _bounded(uint24 fee) internal view returns (uint24) {
        if (fee < FEE_FLOOR) return FEE_FLOOR;
        return fee > FEE_CAP ? FEE_CAP : fee;
    }
}

/// @notice A fee rule that is someone else's contract: a swap pays what a fee module (`FEE_MODULE`) quotes now for one of
/// its own pools (`FEE_POOL_ID`) and the swap's direction, inside the bounds. It is how a pool on a kit hook keeps the
/// fee schedule of a venue's existing pool for the same pair, with nothing new deployed on the venue's side: the module
/// is the venue's own fee hook, and the id its existing pool's. The module is read with a fixed amount of gas
/// (`FEE_READ_GAS`) and may fail in any way: a revert, no code, a short or oversized answer and zero all read as no
/// answer, so the module can make a swap cheaper or dearer inside the bounds and nothing else. A read sent with too
/// little gas for the module to have all of `FEE_READ_GAS` reverts, so the gas a swapper sends cannot choose the floor
/// over the module's fee.
abstract contract ModuleFee is BoundedFee {
    /// @notice The gas the module's quote is read with.
    uint256 public constant FEE_READ_GAS = 100_000;
    /// @dev What a call keeps back for itself (a 64th) is added to `FEE_READ_GAS`, and this for the call's own cost.
    uint256 internal constant FEE_READ_MARGIN = 5000;

    /// @notice The contract whose `currentFee` each swap's fee is read from.
    address public immutable FEE_MODULE;
    /// @notice The module's pool whose fee this hook's pool charges.
    PoolId public immutable FEE_POOL_ID;

    error NoFeeModule();
    error FeeReadGas();

    /// @param feeModule `FEE_MODULE`: a deployed contract.
    /// @param feePoolId `FEE_POOL_ID`.
    constructor(address feeModule, PoolId feePoolId) {
        if (feeModule.code.length == 0) revert NoFeeModule();
        (FEE_MODULE, FEE_POOL_ID) = (feeModule, feePoolId);
    }

    /// @notice The fee a swap in direction `zeroForOne` pays now, in pips: the module's quote inside the bounds.
    function swapFee(bool zeroForOne) external view returns (uint24) {
        return _bounded(_moduleFee(zeroForOne));
    }

    /// @dev The module's quote, or zero for no answer. Read into scratch memory, so an answer of any size costs the
    /// same.
    function _moduleFee(bool zeroForOne) internal view returns (uint24) {
        if (gasleft() < FEE_READ_GAS + FEE_READ_GAS / 63 + FEE_READ_MARGIN) revert FeeReadGas();
        bytes memory data = abi.encodeCall(IRehypoFeeSource.currentFee, (FEE_POOL_ID, zeroForOne));
        address module = FEE_MODULE;
        bool ok;
        uint256 fee;
        assembly ("memory-safe") {
            ok := staticcall(FEE_READ_GAS, module, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            fee := mload(0x00)
        }
        return ok && fee <= type(uint24).max ? uint24(fee) : 0;
    }
}

/// @notice The kit's anchored hook (`AnchoredUnlockCheckedHook`) for a pool whose swap fee is a rule and not a number: a
/// v4 dynamic-fee pool, where this hook names each swap's fee as it starts. The rule is the child's (`_fee`), held
/// inside the bounds (`BoundedFee`). The pool must be a dynamic-fee pool, or its key's fee would be charged and the
/// rule ignored. Nothing else differs: the range, the held position and the unlock check are the parent's. No one can
/// change anything on this hook after deployment. For a pool whose sources have no vault failsafe;
/// `AnchoredFailsafeDynamicFeeHook` is the same on the failsafe hook.
abstract contract AnchoredDynamicFeeHook is AnchoredUnlockCheckedHook, BoundedFee {
    using LPFeeLibrary for uint24;

    constructor(IPoolManager manager, address yieldSource0, address yieldSource1, uint24 feeFloor, uint24 feeCap)
        AnchoredUnlockCheckedHook(manager, yieldSource0, yieldSource1)
        BoundedFee(feeFloor, feeCap)
    {}

    /// @dev The rule: the fee, in pips, for the swap `params` on `key`, before the floor and the cap. Zero for no
    /// answer.
    function _fee(PoolKey calldata key, SwapParams calldata params) internal virtual returns (uint24);

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @dev The swap's fee is returned to the PoolManager as this swap's fee (`OVERRIDE_FEE_FLAG`): the pool's stored
    /// fee is never set and never read.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24)
    {
        uint24 fee = _bounded(_fee(key, params));
        (selector, delta,) = super._beforeSwap(sender, key, params, hookData);
        return (selector, delta, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @notice `AnchoredDynamicFeeHook` on the kit's anchored failsafe hook (`AnchoredFailsafeUnlockCheckedHook`), for a pool
/// whose lent source has the vault failsafe. One thing more differs from the parent: the failsafe's "does this draw
/// pay" test (`_pays`) takes the fee the swap will pay. A dynamic-fee pool stores no fee, so the parent's test, which
/// reads the stored one, would never let a draw through.
abstract contract AnchoredFailsafeDynamicFeeHook is AnchoredFailsafeUnlockCheckedHook, BoundedFee {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint256 minDrawFee0,
        uint256 minDrawFee1,
        uint24 forgonePips,
        uint24 feeFloor,
        uint24 feeCap
    )
        AnchoredFailsafeUnlockCheckedHook(manager, yieldSource0, yieldSource1, minDrawFee0, minDrawFee1, forgonePips)
        BoundedFee(feeFloor, feeCap)
    {}

    /// @dev The rule: the fee, in pips, for the swap `params` on `key`, before the floor and the cap. Zero for no
    /// answer.
    function _fee(PoolKey calldata key, SwapParams calldata params) internal virtual returns (uint24);

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @dev The swap's fee is resolved once, asked of the failsafe with it, and returned to the PoolManager as this
    /// swap's fee (`OVERRIDE_FEE_FLAG`): the pool's stored fee is never set and never read.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24)
    {
        uint24 fee = _bounded(_fee(key, params));
        _askFailsafeAt(key, params, fee);
        (selector, delta,) = super._beforeSwap(sender, key, params, hookData);
        return (selector, delta, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Nothing: `_beforeSwap` has asked already, at the swap's own fee (`_askFailsafeAt`).
    function _askFailsafe(PoolKey calldata, SwapParams calldata) internal pure override {}

    /// @dev The anchored failsafe hook's ask of both sources (`_askBoth`) with one difference: the fee `_pays` is given
    /// is `fee`, the one this swap will pay, where the parent reads the pool's stored fee.
    function _askFailsafeAt(PoolKey calldata key, SwapParams calldata params, uint24 fee) internal {
        (uint160 p,,,) = poolManager.getSlot0(key.toId());
        _askBoth(key, params, p, fee);
    }
}

/// @notice The kit's fee hook for a pool whose sources have no vault failsafe: `AnchoredDynamicFeeHook` with a fee
/// module's quote as its rule (`ModuleFee`). `test/AnchoredFeeHook.t.sol` proves the rule and
/// `test/RehypoSourceRepeat.t.sol` holds the hook to the repeat-round property at its floor.
contract AnchoredFeeHook is AnchoredDynamicFeeHook, ModuleFee {
    constructor(
        IPoolManager manager,
        address yieldSource0,
        address yieldSource1,
        uint24 feeFloor,
        uint24 feeCap,
        address feeModule,
        PoolId feePoolId
    ) AnchoredDynamicFeeHook(manager, yieldSource0, yieldSource1, feeFloor, feeCap) ModuleFee(feeModule, feePoolId) {}

    function _fee(PoolKey calldata, SwapParams calldata params) internal view override returns (uint24) {
        return _moduleFee(params.zeroForOne);
    }
}

/// @notice The kit's fee hook for a pool whose lent source has the vault failsafe: `AnchoredFailsafeDynamicFeeHook` with a
/// fee module's quote as its rule (`ModuleFee`).
contract AnchoredFailsafeFeeHook is AnchoredFailsafeDynamicFeeHook, ModuleFee {
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
        AnchoredFailsafeDynamicFeeHook(
            manager, yieldSource0, yieldSource1, minDrawFee0, minDrawFee1, forgonePips, feeFloor, feeCap
        )
        ModuleFee(feeModule, feePoolId)
    {}

    function _fee(PoolKey calldata, SwapParams calldata params) internal view override returns (uint24) {
        return _moduleFee(params.zeroForOne);
    }
}
