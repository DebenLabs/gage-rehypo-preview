// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModuleFee} from "../src/AnchoredFeeHook.sol";
import {StandingPeggedPair} from "./utils/StandingFixture.sol";
import {FeeModuleProbe} from "./AnchoredFeeHook.t.sol";

/// @dev What both standing fee hooks show of their rule.
interface IStandingFeeHook {
    function swapFee(bool zeroForOne) external view returns (uint24);
    function FEE_FLOOR() external view returns (uint24);
    function FEE_CAP() external view returns (uint24);
    function FEE_MODULE() external view returns (address);
    function FEE_POOL_ID() external view returns (bytes32);
}

/// @notice The kit's standing fee hooks (`StandingAnchoredFeeHook`, and `StandingAnchoredFailsafeFeeHook` where the
/// sources have the vault failsafe) on gage's pegged sources, the cases of `AnchoredFeeHook.t.sol`: a swap pays what the
/// fee module quotes for its direction, held between the floor and the cap; a module that fails in any way charges the
/// floor and stops no swap; the hook refuses a pool whose fee is not dynamic. And what the standing position adds: a
/// swap on a position in place reads the module and calls no source.
abstract contract StandingFeeHookCases is StandingPeggedPair {
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public virtual override {
        super.setUp();
        feeHook = true;
    }

    function _fees() internal view returns (IStandingFeeHook) {
        return IStandingFeeHook(address(key.hooks));
    }

    function _stack(uint24 fee) internal {
        _buildStanding(Run(100, EQUAL, fee, 0, 0));
    }

    /// @dev A small exact-input swap toward the band's edge on that side, and the fee the PoolManager charged it, in
    /// pips, read from its `Swap` event.
    function _feePaid(bool zeroForOne) internal returns (uint24 fee) {
        vm.recordLogs();
        this.swapExact(zeroForOne, zeroForOne ? -int256(10e18) : -int256(10e6), _edgePrice(zeroForOne));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "the swap went through the pool");
    }

    function deployAt(bytes memory args, address at) external {
        deployCodeTo(
            failsafeBps == 0
                ? "StandingFeeHook.sol:StandingAnchoredFeeHook"
                : "StandingFeeHook.sol:StandingAnchoredFailsafeFeeHook",
            args,
            at
        );
    }

    function _args(uint24 floor, uint24 cap, address module) internal view returns (bytes memory) {
        return failsafeBps == 0
            ? abi.encode(address(pm), address(s0), address(s1), floor, cap, module, FEE_POOL)
            : abi.encode(
                address(pm), address(s0), address(s1), uint256(0), uint256(0), uint24(0), floor, cap, module, FEE_POOL
            );
    }

    // ---------------------------------------------------------------- deployment and the pool's key

    function test_theBoundsAreCheckedAtDeployment() public {
        _stack(500);
        address module = address(feeModule);
        address at = address(STANDING_FLAGS | (uint160(0xfee1) << 144));
        vm.expectRevert();
        this.deployAt(_args(99, 500, module), at);
        vm.expectRevert();
        this.deployAt(_args(500, 499, module), at);
        vm.expectRevert();
        this.deployAt(_args(100, 50_001, module), at);
        vm.expectRevert();
        this.deployAt(_args(100, 500, makeAddr("no code here")), at);
        this.deployAt(_args(100, 50_000, module), at);
        IStandingFeeHook hook = IStandingFeeHook(at);
        assertEq(hook.FEE_FLOOR(), 100);
        assertEq(hook.FEE_CAP(), 50_000);
        assertEq(hook.FEE_MODULE(), module);
        assertEq(hook.FEE_POOL_ID(), FEE_POOL);
    }

    function test_aPoolWithAStaticFeeIsRefused() public {
        _sources(Run(100, EQUAL, 500, 0, 0));
        address at = address(STANDING_FLAGS | (uint160(0xfee3) << 144));
        this.deployAt(_args(100, 50_000, address(new FeeModuleProbe())), at);
        PoolKey memory k = PoolKey(Currency.wrap(_token0()), Currency.wrap(_token1()), 500, int24(1), IHooks(at));
        vm.expectRevert();
        pm.initialize(k, _centre());
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        pm.initialize(k, _centre());
    }

    // ---------------------------------------------------------------- the fee a swap pays

    function test_aSwapPaysWhatTheModuleQuotesForItsDirection() public {
        feeBack = 3000;
        _stack(500);
        assertEq(_fees().swapFee(true), 500);
        assertEq(_fees().swapFee(false), 3000);
        assertEq(_feePaid(true), 500, "from token0");
        assertEq(_feePaid(false), 3000, "from token1");
        // The module's quote moves, and the next swap pays the new one: nothing is stored on the pool or the hook.
        feeModule.set(FEE_POOL, 800, 900);
        assertEq(_feePaid(true), 800);
        assertEq(_feePaid(false), 900);
        assertEq(_fees().swapFee(true), 800);
    }

    function test_theQuoteIsHeldBetweenTheFloorAndTheCap() public {
        (feeFloor, feeCap) = (200, 1000);
        _stack(500);
        feeModule.set(FEE_POOL, 50, 5000);
        assertEq(_feePaid(true), 200, "under the floor pays the floor");
        assertEq(_feePaid(false), 1000, "over the cap pays the cap");
        feeModule.set(FEE_POOL, 0, 0);
        assertEq(_feePaid(true), 200, "no quote pays the floor");
        assertEq(_fees().swapFee(false), 200);
    }

    function test_theModuleIsAskedAboutItsOwnPool() public {
        _stack(500);
        assertEq(_feePaid(true), 500);
        feeModule.set(keccak256("another pool"), 500, 500);
        assertEq(_feePaid(true), feeFloor);
    }

    /// @dev Whatever the module does (a revert, all its gas burnt, a short answer, a value past `uint24`, nothing at
    /// all), the swap goes through and pays the floor; an answer of any length is read as its first word.
    function test_aModuleThatFailsChargesTheFloorAndStopsNoSwap() public {
        feeFloor = 300;
        _stack(2000);
        assertEq(_feePaid(true), 2000);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            feeModule.setMode(mode);
            assertEq(_feePaid(mode % 2 == 0), 300, string.concat("mode ", vm.toString(mode)));
            assertEq(_fees().swapFee(true), 300);
        }
        feeModule.setMode(6);
        assertEq(_feePaid(true), 2000, "a long answer is its first word");
    }

    function test_tooLittleGasForTheModuleRevertsTheRead() public {
        _stack(500);
        IStandingFeeHook hook = _fees();
        vm.expectRevert(ModuleFee.FeeReadGas.selector);
        hook.swapFee{gas: 90_000}(true);
        assertEq(hook.swapFee{gas: 200_000}(true), 500);
    }

    // ---------------------------------------------------------------- on the standing position

    /// @dev A swap on a position in place reads the module's quote and calls no source.
    function test_aSwapOnAPlacedPositionReadsTheModuleAndNoSource() public {
        _stack(500);
        // Past the swap that may ask, on the failsafe hook.
        this.swapExact(true, -int256(10e18), _edgePrice(true));
        vm.startStateDiffRecording();
        this.swapExact(true, -int256(100e18), _edgePrice(true));
        this.swapExact(false, -int256(50e6), _edgePrice(false));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_sourceAccesses(accesses), 0, "no call to a source or the vault");
        uint256 reads;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account == address(feeModule)) ++reads;
        }
        assertEq(reads, 2, "one read of the module a swap");
    }

    function test_gas_aSwapOnAPlacedPosition() public {
        _stack(500);
        this.swapExact(true, -int256(10e18), _edgePrice(true));
        uint256 gas = _swapGas(true, -int256(100e18), _edgePrice(true));
        emit log_named_uint("swap through the test router, standing fee hook, position in place (gas)", gas);
    }

    /// @dev With its module quoting one fee, a standing fee hook's pool trades exactly as a static-fee pool at that fee
    /// on the standing hook beside it: twenty-four pushes, keeper passes and stepped trades back end to the unit where
    /// the static pool's do.
    function test_atOneFeeItTradesAsTheStaticFeeStandingHookDoes() public {
        Run[3] memory runs = [Run(100, EQUAL, 500, 0, 0), Run(20, EQUAL, 100, 0, 0), Run(0, EQUAL, 3000, 0, 0)];
        for (uint256 i; i < runs.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            feeHook = false;
            (int256 worst, int256 end) = _roundsStanding(runs[i], 24, NEVER);
            int256 trader_ = _trader();
            vm.revertToStateAndDelete(snapshot);
            snapshot = vm.snapshotState();
            feeHook = true;
            (int256 worstFee, int256 endFee) = _roundsStanding(runs[i], 24, NEVER);
            assertEq(worstFee, worst, _label(runs[i]));
            assertEq(endFee, end, _label(runs[i]));
            assertEq(_trader(), trader_, _label(runs[i]));
            vm.revertToStateAndDelete(snapshot);
        }
    }
}

/// @notice The cases on `StandingAnchoredFeeHook` (sources without the failsafe).
contract StandingFeeHookTest is StandingFeeHookCases {}

/// @notice The cases on `StandingAnchoredFailsafeFeeHook` (both sources have the failsafe). Its draw, judged at the fee
/// the swap pays, is proved in `StandingFailsafeHook.t.sol`.
contract StandingFailsafeFeeHookTest is StandingFeeHookCases {
    function setUp() public override {
        super.setUp();
        failsafeBps = 1000;
    }
}
