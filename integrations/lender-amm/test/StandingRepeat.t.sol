// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StandingPeggedPair, StandingPricedPair, StandingStablePair} from "./utils/StandingFixture.sol";

/// @notice The repeat-round property (`RehypoSourceRepeat.t.sol`) on the kit's standing hooks: the same rounds
/// (a push to the keeper's band edge, alternately below and above, the keeper's pass five minutes on, the trade back
/// to the fair price in steps; 288 rounds, a day), the same bar (the LPs' cumulative loss under a quarter of the
/// smaller side's edge depth at every round), each at a 20% and a 10% float target and at 1, 5 and 30 bp. The keeper's
/// pass is one call to the hook, which takes the position out and moves both sources; the trade back's first swap
/// places it again. Each case runs
/// with the position never taken out between two passes, and with an LP holder taking it out at the worst moment:
/// right after the push, when one side of it has grown the most past what its source opened. On frxUSD/USDG pegged.
contract StandingRepeatPeggedTest is StandingPeggedPair {
    function test_repeat_fullRange() public {
        _holdsStanding(0, EQUAL, NEVER);
    }

    function test_repeat_fullRange_takenOut() public {
        _holdsStanding(0, EQUAL, AFTER_PUSH);
    }

    function test_repeat_point5() public {
        _holdsStanding(100, EQUAL, NEVER);
    }

    function test_repeat_point5_takenOut() public {
        _holdsStanding(100, EQUAL, AFTER_PUSH);
    }

    function test_repeat_point5_kitLayout() public {
        _holdsStanding(100, 10_000, NEVER);
    }

    function test_repeat_point5_kitLayout_takenOut() public {
        _holdsStanding(100, 10_000, AFTER_PUSH);
    }

    function test_repeat_point1() public {
        _holdsStanding(20, EQUAL, NEVER);
    }

    function test_repeat_point1_takenOut() public {
        _holdsStanding(20, EQUAL, AFTER_PUSH);
    }

    /// @dev A take-out between the keeper's pass and the trade back: the pass left the position out already, so it
    /// changes nothing, and the trade back's first swap places it sized afresh.
    function test_repeat_point1_takenOutAfterThePass() public {
        _holdsStanding(20, EQUAL, AFTER_PASS);
    }

    /// @dev Taken out before every swap of the day: each swap places the position again at what it held.
    function test_repeat_point1_takenOutBeforeEverySwap() public {
        _holdsStanding(20, EQUAL, EVERY_SWAP);
    }

    function test_repeat_point01() public {
        _holdsStanding(2, EQUAL, NEVER);
    }

    function test_repeat_point01_takenOut() public {
        _holdsStanding(2, EQUAL, AFTER_PUSH);
    }

    /// @dev The standing hook loses the LPs what the anchored hook loses them, round for round: the same day of rounds
    /// on both, the venue resting at the band's edge, to two basis points of the edge depth.
    function test_itLosesWhatTheAnchoredHookLoses() public {
        _sameAsAnchored(Run(20, EQUAL, 100, 0, 0), 10_048);
        _sameAsAnchored(Run(100, EQUAL, 100, 0, 0), 9952);
        _sameAsAnchored(Run(100, EQUAL, 500, 0, 0), 10_000);
    }

    function _sameAsAnchored(Run memory r, uint256 fair) internal {
        fairBps = fair;
        uint256 snapshot = vm.snapshotState();
        (int256 worstAnchored, int256 endAnchored) = _roundsAnchored(r, ROUNDS);
        vm.revertToStateAndDelete(snapshot);
        snapshot = vm.snapshotState();
        (int256 worst, int256 end) = _roundsStanding(r, ROUNDS, NEVER);
        vm.revertToStateAndDelete(snapshot);
        console2.log(
            string.concat(
                _label(r),
                ": worst loss (bps of the smaller edge), anchored ",
                vm.toString(worstAnchored),
                ", standing ",
                vm.toString(worst)
            )
        );
        assertApproxEqAbs(worst, worstAnchored, 2, "the worst of the day");
        // The day's fees leave the trader a hundred or a thousand edge depths down: to a ten-thousandth of that.
        uint256 within = 2 + uint256(endAnchored < 0 ? -endAnchored : endAnchored) / 10_000;
        assertApproxEqAbs(end, endAnchored, within, "after the day");
        fairBps = 10_000;
    }

    // --------------------------------------- the venue resting off the signed price inside the band, equal targets

    /// @dev frxUSD's venue 0.2% and 0.48% (the band's edge less the push's margin) over the signed price.
    function test_offCentre_above_point5() public {
        _holdsStandingOffAnchor(100, [uint256(10_020), 10_048], NEVER);
    }

    function test_offCentre_above_point5_takenOut() public {
        _holdsStandingOffAnchor(100, [uint256(10_020), 10_048], AFTER_PUSH);
    }

    function test_offCentre_above_point1() public {
        _holdsStandingOffAnchor(20, [uint256(10_020), 10_048], NEVER);
    }

    function test_offCentre_above_point1_takenOut() public {
        _holdsStandingOffAnchor(20, [uint256(10_020), 10_048], AFTER_PUSH);
    }

    function test_offCentre_below_point5() public {
        _holdsStandingOffAnchor(100, [uint256(9980), 9952], NEVER);
    }

    function test_offCentre_below_point5_takenOut() public {
        _holdsStandingOffAnchor(100, [uint256(9980), 9952], AFTER_PUSH);
    }

    /// @dev Below the signed price a +-0.1% range holds the bound with the venue up to 0.25% under it, as on the
    /// anchored hook (`RehypoSourceRepeatPeggedTest.test_offCentre_below_point1`).
    function test_offCentre_below_point1() public {
        _holdsStandingOffAnchor(20, [uint256(9980), 9975], NEVER);
    }

    function test_offCentre_below_point1_takenOut() public {
        _holdsStandingOffAnchor(20, [uint256(9980), 9975], AFTER_PUSH);
    }

    function test_offCentre_below_point1_takenOutBeforeEverySwap() public {
        _holdsStandingOffAnchor(20, [uint256(9980), 9975], EVERY_SWAP);
    }
}

/// @notice The property on NVDA/USDG, both sources priced, at the cap-free width of their band: the narrowest declared
/// range at which the source's cap inside the band opens its whole float target (`_capFreeTicks`). Run at the +-1% band
/// of `RehypoSourceRepeat.t.sol` and, in `StandingRepeatPricedTightTest`, at a +-0.30% band (605 ticks).
contract StandingRepeatPricedTest is StandingPricedPair {
    /// @dev The fair prices off the anchor the rounds rest at: a fifth of the band, and 95% of it (the push's edge).
    function _off(bool above) internal view returns (uint256[2] memory) {
        uint256 near = uint256(bandBps) / 5;
        uint256 far = uint256(bandBps) * 95 / 100;
        return above ? [10_000 + near, 10_000 + far] : [10_000 - near, 10_000 - far];
    }

    function _width() internal view returns (uint24) {
        return _capFreeTicks(bandBps);
    }

    /// @dev At that width a keeper's move caps the swap float at the whole float target; a tick narrower, under it.
    function test_atTheCapFreeWidthTheCapIsTheFloatTarget() public {
        uint24 width = _width();
        console2.log("band (bps) and its cap-free width (ticks):", bandBps, width);
        uint256 snapshot = vm.snapshotState();
        _buildStanding(Run(width, EQUAL, 100, 0, 0));
        (uint256 b0, uint256 b1) = _backing();
        assertApproxEqRel(s0.swapCap(), Math.mulDiv(b0, s0.floatBps(), 10_000), 1e12, "token0: the whole target");
        assertApproxEqRel(s1.swapCap(), Math.mulDiv(b1, s1.floatBps(), 10_000), 1e12, "token1: the whole target");
        vm.revertToStateAndDelete(snapshot);
        _buildStanding(Run(width - 1, EQUAL, 100, 0, 0));
        (b0, b1) = _backing();
        assertLt(s0.swapCap(), Math.mulDiv(b0, s0.floatBps(), 10_000) - 1e6, "a tick narrower the cap binds");
        assertLt(s1.swapCap(), Math.mulDiv(b1, s1.floatBps(), 10_000) - 1);
    }

    function test_repeat_capFree() public {
        _holdsStanding(_width(), EQUAL, NEVER);
    }

    function test_repeat_capFree_takenOut() public {
        _holdsStanding(_width(), EQUAL, AFTER_PUSH);
    }

    function test_repeat_capFree_takenOutAfterThePass() public {
        _holdsStanding(_width(), EQUAL, AFTER_PASS);
    }

    /// @dev The kit's layout, the float-only side at 100%: at this width a priced pair's two targets may differ.
    function test_repeat_capFree_kitLayout() public {
        _holdsStanding(_width(), 10_000, NEVER);
    }

    function test_repeat_capFree_kitLayout_takenOut() public {
        _holdsStanding(_width(), 10_000, AFTER_PUSH);
    }

    function test_offCentre_above_capFree() public {
        _holdsStandingOffAnchor(_width(), _off(true), NEVER);
    }

    function test_offCentre_above_capFree_takenOut() public {
        _holdsStandingOffAnchor(_width(), _off(true), AFTER_PUSH);
    }

    function test_offCentre_below_capFree() public {
        _holdsStandingOffAnchor(_width(), _off(false), NEVER);
    }

    function test_offCentre_below_capFree_takenOut() public {
        _holdsStandingOffAnchor(_width(), _off(false), AFTER_PUSH);
    }

    /// @dev Taken out before every swap of the day, the source's cap (its float target, at this width) applied each
    /// time the position comes back.
    function test_offCentre_below_capFree_takenOutBeforeEverySwap() public {
        _holdsStandingOffAnchor(_width(), _off(false), EVERY_SWAP);
    }

    function test_repeat_capFree_takenOutBeforeEverySwap() public {
        _holdsStanding(_width(), EQUAL, EVERY_SWAP);
    }

    /// @dev The standing hook loses the LPs what the anchored hook loses them on the same day of rounds, at the anchor
    /// and with the venue resting at the band's edge either way, to two basis points of the edge depth.
    function test_itLosesWhatTheAnchoredHookLoses() public {
        Run memory r = Run(_width(), EQUAL, 100, 0, 0);
        uint256[3] memory fairs = [uint256(10_000), _off(true)[1], _off(false)[1]];
        for (uint256 i; i < fairs.length; ++i) {
            fairBps = fairs[i];
            uint256 snapshot = vm.snapshotState();
            (int256 worstAnchored,) = _roundsAnchored(r, ROUNDS);
            vm.revertToStateAndDelete(snapshot);
            snapshot = vm.snapshotState();
            (int256 worst,) = _roundsStanding(r, ROUNDS, NEVER);
            vm.revertToStateAndDelete(snapshot);
            console2.log(
                string.concat(
                    _label(r),
                    ": worst loss (bps of the smaller edge), anchored ",
                    vm.toString(worstAnchored),
                    ", standing ",
                    vm.toString(worst)
                )
            );
            assertApproxEqAbs(worst, worstAnchored, 2, "the worst of the day");
        }
        fairBps = 10_000;
    }
}

/// @notice The priced pair's cases at a +-0.30% band, the stock and ETH pools' proposed setting (605 ticks).
contract StandingRepeatPricedTightTest is StandingRepeatPricedTest {
    function setUp() public override {
        super.setUp();
        bandBps = 30;
    }

    function test_theWidthIs605Ticks() public view {
        assertEq(_width(), 605);
    }
}

/// @notice The property on the standing fee hook (`StandingAnchoredFeeHook`, a dynamic-fee pool), its module quoting
/// each of the same fees and a different fee each way, on the pegged pair.
contract StandingRepeatPeggedFeeHookTest is StandingPeggedPair {
    function setUp() public override {
        super.setUp();
        feeHook = true;
    }

    function test_repeat_point5() public {
        _holdsStanding(100, EQUAL, NEVER);
    }

    function test_repeat_point01_takenOut() public {
        _holdsStanding(2, EQUAL, AFTER_PUSH);
    }

    function test_offCentre_above_point1_takenOut() public {
        _holdsStandingOffAnchor(20, [uint256(10_020), 10_048], AFTER_PUSH);
    }

    /// @dev Each fee one way against 30 bp, then against 1 bp, the other way.
    function test_repeat_point1_aDifferentFeeEachWay() public {
        feeBack = 3000;
        _holdsStanding(20, EQUAL, NEVER);
        feeBack = 100;
        _holdsStanding(20, EQUAL, AFTER_PUSH);
    }
}

/// @notice The property on the standing fee hook, the priced pair at its cap-free width.
contract StandingRepeatPricedFeeHookTest is StandingPricedPair {
    function setUp() public override {
        super.setUp();
        feeHook = true;
        bandBps = 30;
    }

    function test_repeat_capFree() public {
        _holdsStanding(_capFreeTicks(bandBps), EQUAL, NEVER);
    }

    function test_offCentre_capFree_takenOut() public {
        _holdsStandingOffAnchor(_capFreeTicks(bandBps), [uint256(10_028), 9972], AFTER_PUSH);
    }

    function test_repeat_capFree_kitLayout_aDifferentFeeEachWay() public {
        feeBack = 3000;
        _holdsStanding(_capFreeTicks(bandBps), 10_000, AFTER_PUSH);
        feeBack = 100;
        _holdsStanding(_capFreeTicks(bandBps), 10_000, NEVER);
    }
}

/// @notice The property on the standing failsafe hook (`StandingAnchoredFailsafeHook`), frxUSD/USDG pegged with the
/// failsafe on both sources, against the trader the ask serves best, as `RehypoSourceRepeatPeggedFailsafeTest` runs it
/// on the anchored failsafe hook: a keeper pass before every push, so the push is the first swap on a position sized
/// afresh and draws a tenth of each side's backing on top of its float, and the trade back in one swap after the next
/// pass, which draws again. Every swap of the day takes the topped-up position.
contract StandingRepeatPeggedFailsafeTest is StandingPeggedPair {
    function setUp() public virtual override {
        super.setUp();
        failsafeBps = 1000;
    }

    function test_repeat_point5_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStanding(100, EQUAL, NEVER);
    }

    function test_repeat_point25_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStanding(50, EQUAL, NEVER);
    }

    function test_repeat_point25_everySwapAsks_takenOut() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStanding(50, EQUAL, AFTER_PUSH);
    }

    function test_repeat_point1_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStanding(20, EQUAL, NEVER);
    }

    /// @dev The usual rounds: the push runs on the position the last trade back left, and only the trade back's first
    /// step may ask.
    function test_repeat_point25_theUsualRounds() public {
        _holdsStanding(50, EQUAL, NEVER);
    }

    function test_repeat_point25_theUsualRounds_takenOut() public {
        _holdsStanding(50, EQUAL, AFTER_PUSH);
    }

    /// @dev frxUSD's venue 0.2% off the signed price, either way.
    function test_offCentre_point25_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStandingOffAnchor(50, [uint256(10_020), 9980], NEVER);
    }

    /// @dev Those rounds do draw: the push after a keeper pass takes each side's whole room, and so does the one-swap
    /// trade back after the next pass.
    function test_inThoseRoundsEveryPushAndTradeBackDraws() public {
        vm.pauseGasMetering();
        _buildStanding(Run(50, EQUAL, 500, 0, 0));
        uint256 cash = vault.cash();
        assertGt(IRepeatRoom(address(s0)).failsafeLeft(), 0);
        _swapTo(_edgePrice(true));
        assertLe(IRepeatRoom(address(s0)).failsafeLeft(), 1e12, "the push took the frxUSD room");
        assertLe(IRepeatRoom(address(s1)).failsafeLeft(), 2, "and the USDG room, from the vault");
        assertLt(vault.cash(), cash);
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        cash = vault.cash();
        _stepTo(_fair(), 1);
        assertLe(IRepeatRoom(address(s1)).failsafeLeft(), 2, "the trade back took it again");
        assertLt(vault.cash(), cash);
        vm.resumeGasMetering();
    }
}

/// @notice The same on the standing failsafe fee hook (`StandingAnchoredFailsafeFeeHook`).
contract StandingRepeatPeggedFailsafeFeeHookTest is StandingPeggedPair {
    function setUp() public override {
        super.setUp();
        (failsafeBps, feeHook) = (1000, true);
    }

    function test_repeat_point25_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsStanding(50, EQUAL, NEVER);
    }

    function test_repeat_point25_theUsualRounds_takenOut() public {
        _holdsStanding(50, EQUAL, AFTER_PUSH);
    }
}

interface IRepeatRoom {
    function failsafeLeft() external view returns (uint256);
}

/// @notice A probe for the scope's fourth decision, not the proof: a stable pair declared narrower than the full range,
/// whose sources cap their swap float inside the band, which the standing hooks are not offered for. The same day of
/// rounds on the anchored hook and on the standing hook, the position never taken out and taken out after each push,
/// at 1 bp with equal targets: the LPs lose the same on all three. The hook's other cases, the fee and failsafe hooks
/// and a swap's input past the cap between two keeper moves are not run here.
contract StandingRepeatCappedStableProbeTest is StandingStablePair {
    function _probe(uint24 declared, uint256 fair) internal {
        fairBps = fair;
        Run memory r = Run(declared, EQUAL, 100, 0, 0);
        uint256 snapshot = vm.snapshotState();
        (int256 anchored,) = _roundsAnchored(r, ROUNDS);
        vm.revertToStateAndDelete(snapshot);
        snapshot = vm.snapshotState();
        (int256 standing,) = _roundsStanding(r, ROUNDS, NEVER);
        vm.revertToStateAndDelete(snapshot);
        snapshot = vm.snapshotState();
        (int256 takenOut,) = _roundsStanding(r, ROUNDS, AFTER_PUSH);
        vm.revertToStateAndDelete(snapshot);
        console2.log(
            string.concat(
                "capped stable range, ",
                _label(r),
                ": worst loss (bps of the smaller edge), anchored ",
                vm.toString(anchored),
                ", standing ",
                vm.toString(standing),
                ", taken out after each push ",
                vm.toString(takenOut)
            )
        );
        assertLe(standing, BAR);
        assertLe(takenOut, BAR);
        assertApproxEqAbs(standing, anchored, 2);
        assertApproxEqAbs(takenOut, anchored, 2);
        fairBps = 10_000;
    }

    function test_probe_point5() public {
        _probe(100, 10_000);
        _probe(100, 10_048);
        _probe(100, 9952);
    }

    function test_probe_point1() public {
        _probe(20, 10_000);
        _probe(20, 10_048);
        _probe(20, 9952);
    }

    function test_probe_point01() public {
        _probe(2, 10_000);
        _probe(2, 10_048);
        _probe(2, 9952);
    }
}
