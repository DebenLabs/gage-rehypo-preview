// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RehypoRepeatStablePair} from "./RehypoSourceRepeat.t.sol";
import {ModuleFee} from "../src/AnchoredFeeHook.sol";

/// @dev What both fee hooks show of their rule.
interface IFeeHook {
    function swapFee(bool zeroForOne) external view returns (uint24);
    function FEE_FLOOR() external view returns (uint24);
    function FEE_CAP() external view returns (uint24);
    function FEE_MODULE() external view returns (address);
    function FEE_POOL_ID() external view returns (bytes32);
}

/// @notice The kit's fee hooks (`AnchoredFeeHook`, and `AnchoredFailsafeFeeHook` where the lent source has the vault
/// failsafe) on gage's sources, frxUSD/USDG: a swap pays what the fee module quotes for its direction, held between the
/// floor and the cap; a module that fails in any way charges the floor and stops no swap; the hook refuses a pool whose
/// fee is not dynamic. Each case runs on the hook the stack's sources call for (`failsafeBps`).
abstract contract FeeHookCases is RehypoRepeatStablePair {
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public virtual override {
        super.setUp();
        feeHook = true;
    }

    function _hook() internal view returns (IFeeHook) {
        return IFeeHook(address(key.hooks));
    }

    function swapExact(bool zeroForOne, int256 amount, uint160 limit) external {
        require(msg.sender == address(this));
        vm.prank(trader, trader);
        router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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
            failsafeBps == 0 ? "AnchoredFeeHook.sol:AnchoredFeeHook" : "AnchoredFeeHook.sol:AnchoredFailsafeFeeHook",
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
        _build(Run(100, 10_000, 500, 0, 0));
        address module = address(feeModule);
        address at = address(FLAGS | (uint160(0xfee1) << 144));
        vm.expectRevert();
        this.deployAt(_args(99, 500, module), at);
        vm.expectRevert();
        this.deployAt(_args(500, 499, module), at);
        vm.expectRevert();
        this.deployAt(_args(100, 50_001, module), at);
        vm.expectRevert();
        this.deployAt(_args(100, 500, makeAddr("no code here")), at);
        // The widest bounds, and a floor that is also the cap, deploy.
        this.deployAt(_args(100, 50_000, module), at);
        this.deployAt(_args(700, 700, module), address(FLAGS | (uint160(0xfee2) << 144)));
        IFeeHook hook = IFeeHook(at);
        assertEq(hook.FEE_FLOOR(), 100);
        assertEq(hook.FEE_CAP(), 50_000);
        assertEq(hook.FEE_MODULE(), module);
        assertEq(hook.FEE_POOL_ID(), FEE_POOL);
    }

    function test_aPoolWithAStaticFeeIsRefused() public {
        _sources(Run(100, 10_000, 500, 0, 0));
        address at = address(FLAGS | (uint160(0xfee3) << 144));
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
        _build(Run(100, 10_000, 500, 0, 0));
        assertEq(_hook().swapFee(true), 500);
        assertEq(_hook().swapFee(false), 3000);
        assertEq(_feePaid(true), 500, "from token0");
        assertEq(_feePaid(false), 3000, "from token1");
        // The module's quote moves, and the next swap pays the new one: nothing is stored on the pool or the hook.
        feeModule.set(FEE_POOL, 800, 900);
        assertEq(_feePaid(true), 800);
        assertEq(_feePaid(false), 900);
        assertEq(_hook().swapFee(true), 800);
    }

    function test_theQuoteIsHeldBetweenTheFloorAndTheCap() public {
        (feeFloor, feeCap) = (200, 1000);
        _build(Run(100, 10_000, 500, 0, 0));
        feeModule.set(FEE_POOL, 50, 5000);
        assertEq(_feePaid(true), 200, "under the floor pays the floor");
        assertEq(_feePaid(false), 1000, "over the cap pays the cap");
        feeModule.set(FEE_POOL, 200, 1000);
        assertEq(_feePaid(true), 200, "the floor itself");
        assertEq(_feePaid(false), 1000, "the cap itself");
        feeModule.set(FEE_POOL, 0, 0);
        assertEq(_feePaid(true), 200, "no quote pays the floor");
        assertEq(_hook().swapFee(false), 200);
    }

    function test_theModuleIsAskedAboutItsOwnPool() public {
        _build(Run(100, 10_000, 500, 0, 0));
        assertEq(_feePaid(true), 500);
        // The same quote for another pool is no answer for this hook's.
        feeModule.set(keccak256("another pool"), 500, 500);
        assertEq(_feePaid(true), feeFloor);
    }

    /// @dev Property: whatever the module does (a revert, all its gas burnt, a short answer, a value past `uint24`,
    /// nothing at all), the swap goes through and pays the floor; an answer of any length is read as its first word.
    function test_aModuleThatFailsChargesTheFloorAndStopsNoSwap() public {
        feeFloor = 300;
        _build(Run(100, 10_000, 2000, 0, 0));
        assertEq(_feePaid(true), 2000);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            feeModule.setMode(mode);
            assertEq(_feePaid(mode % 2 == 0), 300, string.concat("mode ", vm.toString(mode)));
            assertEq(_hook().swapFee(true), 300);
        }
        feeModule.setMode(6);
        assertEq(_feePaid(true), 2000, "a long answer is its first word");
    }

    function test_tooLittleGasForTheModuleRevertsTheRead() public {
        _build(Run(100, 10_000, 500, 0, 0));
        IFeeHook hook = _hook();
        vm.expectRevert(ModuleFee.FeeReadGas.selector);
        hook.swapFee{gas: 90_000}(true);
        assertEq(hook.swapFee{gas: 200_000}(true), 500);
    }
}

/// @notice The cases on `AnchoredFeeHook` (sources without the failsafe), and the property that lets the repeat rounds
/// (`RehypoSourceRepeat.t.sol`) speak for both fee hooks: at one fee they trade, round for round, exactly as the
/// static-fee hooks do.
contract AnchoredFeeHookTest is FeeHookCases {
    /// @dev Property: with its module quoting one fee, a fee hook's pool trades exactly as a static-fee pool at that
    /// fee on the kit's anchored hooks: twenty-four pushes, keeper passes and stepped trades back end to the unit where
    /// the static pool's do, without and with the failsafe (each on its own hook), on a declared range and the full one.
    function test_atOneFeeItTradesAsTheStaticFeeHooksDo() public {
        Run[3] memory runs = [Run(100, EQUAL, 500, 0, 0), Run(20, 10_000, 100, 0, 0), Run(0, 10_000, 3000, 0, 0)];
        for (uint256 i; i < runs.length; ++i) {
            for (uint16 failsafe; failsafe <= 1000; failsafe += 1000) {
                uint256 snapshot = vm.snapshotState();
                (feeHook, failsafeBps) = (false, failsafe);
                (int256 worst, int256 end) = _rounds(runs[i], 24);
                int256 trader_ = _trader();
                vm.revertToStateAndDelete(snapshot);
                snapshot = vm.snapshotState();
                (feeHook, failsafeBps) = (true, failsafe);
                (int256 worstFee, int256 endFee) = _rounds(runs[i], 24);
                assertEq(worstFee, worst, _label(runs[i]));
                assertEq(endFee, end, _label(runs[i]));
                assertEq(_trader(), trader_, _label(runs[i]));
                vm.revertToStateAndDelete(snapshot);
            }
        }
    }
}

/// @notice The cases on `AnchoredFailsafeFeeHook` (both sources have the failsafe). Its draw, judged at the fee the swap
/// pays, is proved where both sides have room, on pegged sources: `AnchoredFailsafeAsk.t.sol`.
contract AnchoredFailsafeFeeHookTest is FeeHookCases {
    function setUp() public override {
        super.setUp();
        failsafeBps = 1000;
    }
}

/// @dev Any contract with code: a module is only read at a swap.
contract FeeModuleProbe {
    function currentFee(bytes32, bool) external pure returns (uint24) {
        return 500;
    }
}
