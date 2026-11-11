// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StandingPeggedPair} from "./utils/StandingFixture.sol";

interface IRoom {
    function failsafeLeft() external view returns (uint256);
}

interface IDrawEconomics {
    function MIN_DRAW_FEE_0() external view returns (uint256);
    function MIN_DRAW_FEE_1() external view returns (uint256);
    function FORGONE_PIPS() external view returns (uint24);
}

/// @notice The standing failsafe hook's ask (`StandingFailsafe._ask`), on gage's pegged sources, the stack of
/// `AnchoredFailsafeAsk.t.sol`: frxUSD/USDG at one for one on a +-0.25% range, a 10% float either side and a tenth of
/// each side's backing kept free for swaps. The first swap after a keeper's move that would move the pool's price more
/// than the tolerance on the position asks both sources for the same share of what they back, and what they give tops
/// the position up and stays in it: the swap fills as it does on the anchored failsafe hook. A swap the position fills
/// inside the tolerance, one its own limit stops there and one that would not pay ask nothing and call no source; no
/// later swap asks until the position is sized afresh again.
contract StandingFailsafeHookTest is StandingPeggedPair {
    /// @dev +-0.25%, equal float targets, 0.05% fee.
    uint24 internal constant WIDTH = 50;
    uint24 internal constant FEE = 500;

    function setUp() public virtual override {
        super.setUp();
        failsafeBps = 1000;
        lentBps = 1000;
    }

    function _stack() internal {
        _buildStanding(Run(WIDTH, EQUAL, FEE, 0, 0));
    }

    /// @dev frxUSD sold with no price limit: what the trader received in USDG.
    function _sell(uint256 frx) internal returns (uint256 got) {
        (, got) = _trade(-int256(frx), TickMath.MIN_SQRT_PRICE + 1);
    }

    function _room0() internal view returns (uint256) {
        return IRoom(address(s0)).failsafeLeft();
    }

    function _room1() internal view returns (uint256) {
        return IRoom(address(s1)).failsafeLeft();
    }

    /// @dev The pool's price as a share of `from`, in millionths of the price (a sqrt price, squared).
    function _movedTo(uint160 from) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(_price(), 1e6, from), _price(), from);
    }

    function test_theFirstSwapPlacesATenthAndATenthStaysFreeEitherSide() public {
        _stack();
        assertEq(_liquidity(), 0, "the keeper's move places nothing");
        assertApproxEqAbs(s0.swapFloat(), 10_000e18, 1e12, "frxUSD: a tenth open, all of it in the source");
        assertApproxEqAbs(s1.swapFloat(), 10_000e6, 2, "USDG: a tenth open");
        _dustSwap();
        (uint256 a0, uint256 a1) = _hook().positionAmounts();
        assertApproxEqAbs(a0 + s0.swapFloat(), 10_000e18, 1e12, "frxUSD: a tenth open, in the position and beside it");
        assertApproxEqAbs(a1 + s1.swapFloat(), 10_000e6, 2, "USDG: a tenth open");
        assertGt(a0, 9000e18, "most of it in the position");
        assertGt(a1, 9000e6);
        assertApproxEqAbs(_room0(), 10_000e18, 1e12, "frxUSD: a tenth more may open, from the float it keeps closed");
        assertApproxEqAbs(_room1(), 10_000e6, 1, "USDG: a tenth more may come from the vault's free cash");
        IDrawEconomics hook = IDrawEconomics(address(key.hooks));
        assertEq(hook.MIN_DRAW_FEE_0() + hook.MIN_DRAW_FEE_1() + hook.FORGONE_PIPS(), 0);
    }

    /// @dev The position backs about 1,925 USDG inside 0.05%: a 1,500 frxUSD sale, the first swap after the keeper's
    /// move, places the position and asks nothing; the same sale again calls no source at all.
    function test_aSwapThePositionFillsInsideTheToleranceAsksNothing() public {
        _stack();
        (uint256 room0, uint256 room1, uint256 cash) = (_room0(), _room1(), vault.cash());
        uint128 liquidity = _placing();
        uint160 p = _price();
        uint256 got = _sell(1500e18);
        assertGt(got, 0);
        assertEq(_room0(), room0, "nothing asked of either source");
        assertEq(_room1(), room1);
        assertEq(vault.cash(), cash, "nor of the vault");
        assertEq(_liquidity(), liquidity, "the position as placed, not topped up");
        assertGe(_movedTo(p), 1e6 - 500, "inside the tolerance on the position alone");
        _trade(-int256(1e27), p);
        vm.startStateDiffRecording();
        got = _sell(1500e18);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertGt(got, 0);
        assertEq(_sourceAccesses(accesses), 0, "on the position in place, no call to a source");
    }

    /// @dev A 3,000 frxUSD sale needs over half as much liquidity again: both sources give the same share of what they
    /// back, the position is topped up with it and stays in, and the sale pays the trader what it pays on the anchored
    /// failsafe hook.
    function test_aSwapPastTheToleranceDrawsBothCoinsAndTopsThePositionUp() public {
        uint256 snapshot = vm.snapshotState();
        _buildAnchored(Run(WIDTH, EQUAL, FEE, 0, 0));
        uint256 anchored = _sell(3000e18);
        uint256 anchoredRoom1 = _room1();
        vm.revertToStateAndDelete(snapshot);

        _stack();
        (uint256 room0, uint256 room1, uint256 cash) = (_room0(), _room1(), vault.cash());
        uint128 liquidity = _placing();
        (uint256 b0, uint256 b1) = _backing();
        uint160 start = _price();
        uint256 got = _sell(3000e18);
        (uint256 drew0, uint256 drew1) = (room0 - _room0(), room1 - _room1());
        assertApproxEqRel(drew1, 5570e6, 0.01e18, "the share that lets the sale fill inside the tolerance");
        assertApproxEqRel(drew0 / 1e12, drew1, 0.001e18, "the same share of the frxUSD, from the float it kept closed");
        assertEq(cash - vault.cash(), drew1, "the USDG from the vault's free cash, inside the swap");
        assertApproxEqAbs(_room1(), anchoredRoom1, 2, "what the anchored failsafe hook draws");
        assertGe(_movedTo(start), 1e6 - 501, "the sale ends inside the tolerance");
        assertApproxEqRel(got, anchored, 1e10, "and pays what it pays on the anchored failsafe hook");
        assertApproxEqRel(
            _liquidity(), uint256(liquidity) * (10_000e6 + drew1) / 10_000e6, 0.001e18, "the position, topped up"
        );
        (uint256 c0, uint256 c1) = _backing();
        assertApproxEqAbs(c0, b0 + 3000e18, 1e4, "the draw moved the backing nowhere: only the sale did");
        assertApproxEqAbs(c1 + got, b1, 4);
    }

    /// @dev The other way: USDG sold for frxUSD draws both the same.
    function test_buyingTheOtherCoinAsksTheSame() public {
        _stack();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        uint160 start = _price();
        _trade(-int256(3000e6), TickMath.MAX_SQRT_PRICE - 1);
        (uint256 drew0, uint256 drew1) = (room0 - _room0(), room1 - _room1());
        assertApproxEqRel(drew0, 5580e18, 0.01e18, "the share that lets the buy fill inside the tolerance");
        assertApproxEqRel(drew1, drew0 / 1e12, 0.001e18);
        assertLe(_movedTo(start), 1e6 + 501, "the buy ends inside the tolerance");
    }

    /// @dev A sale far larger than both rooms: each source gives its room and no more.
    function test_neverMoreThanEachSourcesRoom() public {
        _stack();
        uint128 liquidity = _placing();
        _sell(15_000e18);
        assertEq(_room0(), 0, "all of the frxUSD room");
        assertLe(_room1(), 2, "all of the USDG room, to a rounding of the position's count and one of the step");
        assertApproxEqRel(_liquidity(), uint256(liquidity) * 2, 0.001e18, "the position, doubled");
    }

    /// @dev The vault has 1,000 USDG free: the USDG source gives that, and the frxUSD source is asked for the same
    /// share, not for what the sale first needed.
    function test_theSideThatGivesLessSetsTheOther() public {
        _stack();
        vault.lend(vault.cash() - 1000e6);
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        _sell(3000e18);
        (uint256 drew0, uint256 drew1) = (room0 - _room0(), room1 - _room1());
        assertApproxEqAbs(drew1, 1000e6, 1, "all the vault could pay");
        assertApproxEqRel(drew0 / 1e12, drew1, 0.001e18, "and the frxUSD in step");
    }

    /// @dev A sale that names 15,000 frxUSD and stops 0.03% under the price takes what the position gives there and
    /// asks nothing; stopped past the tolerance, it asks.
    function test_aSwapItsOwnLimitStopsInsideTheToleranceAsksNothing() public {
        _stack();
        (uint256 room0, uint256 room1, uint256 cash) = (_room0(), _room1(), vault.cash());
        uint160 p = _price();
        uint256 snapshot = vm.snapshotState();
        this.swapExact(true, -int256(15_000e18), uint160(Math.mulDiv(p, 999_850, 1e6)));
        assertEq(_room0(), room0);
        assertEq(_room1(), room1);
        assertEq(vault.cash(), cash);
        vm.revertToStateAndDelete(snapshot);
        this.swapExact(true, -int256(15_000e18), uint160(Math.mulDiv(p, 999_500, 1e6)));
        assertLt(_room1(), room1, "a limit past the tolerance lets it ask");
        assertLt(_room0(), room0);
    }

    /// @dev Only the first swap after a position sized afresh may ask: a later swap asks nothing, however large, and
    /// calls no source; the first swap after the keeper's next move asks again.
    function test_onlyTheFirstSwapAfterAFreshPlacingAsks() public {
        _stack();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        _sell(500e18);
        vm.startStateDiffRecording();
        _sell(3000e18);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_sourceAccesses(accesses), 0, "the second swap calls no source");
        assertEq(_room0(), room0, "and asks nothing");
        assertEq(_room1(), room1);
        _trade(-int256(1e27), _centre());
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        (room0, room1) = (_room0(), _room1());
        _sell(3000e18);
        assertLt(_room0(), room0, "sized afresh: it asks");
        assertLt(_room1(), room1);
    }

    /// @dev A position placed again at the liquidity it held (after a take-out, or an LP move) does not ask.
    function test_aPositionPlacedAgainAtWhatItHeldDoesNotAsk() public {
        _stack();
        _dustSwap();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        uint128 liquidity = _liquidity();
        _holderTakesOut();
        _sell(3000e18);
        assertEq(_room0(), room0, "after a take-out");
        assertEq(_room1(), room1);
        assertApproxEqRel(_liquidity(), liquidity, 1e9);
        uint256 shares = _hook().totalSupply() / 10;
        vm.prank(trader);
        _hook().addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        _sell(3000e18);
        assertEq(_room0(), room0, "after an LP entry");
        assertEq(_room1(), room1);
    }

    /// @dev What was drawn stays in the position through a take-out: placed again, it holds the topped-up liquidity.
    function test_theToppedUpPositionIsHeldThroughATakeOut() public {
        _stack();
        uint128 before = _placing();
        _sell(3000e18);
        uint128 toppedUp = _liquidity();
        assertGt(toppedUp, before);
        _holderTakesOut();
        assertEq(_hook().heldLiquidity(), toppedUp);
        this.swapExact(true, -1, _price() - 1);
        assertApproxEqRel(_liquidity(), toppedUp, 1e9, "the same liquidity, the draw in it");
        assertLe(_liquidity(), toppedUp);
    }

    /// @dev A draw must earn its cost: with 5 USDG to earn, the fee on half of a 5,570 USDG ask is 1.4 USDG at 0.05%
    /// and 8.4 USDG at 0.3%.
    function test_aDrawThatWouldNotPayIsNotAsked() public {
        drawFee1 = 5e6;
        uint256 snapshot = vm.snapshotState();
        _stack();
        uint256 room1 = _room1();
        _sell(3000e18);
        assertEq(_room1(), room1, "at 0.05% it does not pay");
        vm.revertToStateAndDelete(snapshot);
        _buildStanding(Run(WIDTH, EQUAL, 3000, 0, 0));
        assertEq(IDrawEconomics(address(key.hooks)).MIN_DRAW_FEE_1(), 5e6);
        room1 = _room1();
        _sell(3000e18);
        assertLt(_room1(), room1, "at 0.3% it does");
    }

    /// @dev On the full range (before the first keeper move) a first swap asks nothing: a source has no room there.
    function test_onTheFullRangeNothingIsAsked() public {
        noFirstPass = true;
        _stack();
        noFirstPass = false;
        uint256 cash = vault.cash();
        _sell(3000e18);
        assertEq(vault.cash(), cash);
        assertEq(_room0() + _room1(), 0);
    }

    /// @dev The draw economics are checked at deployment, as the failsafe hook's are.
    function test_theForgoneShareIsBoundedAtDeployment() public {
        _stack();
        address at = address(STANDING_FLAGS | (uint160(0xfa11) << 144));
        vm.expectRevert();
        this.deployFailsafeAt(abi.encode(address(pm), address(s0), address(s1), 0, 0, uint24(10_001)), at);
        this.deployFailsafeAt(abi.encode(address(pm), address(s0), address(s1), 1, 2, uint24(10_000)), at);
        assertEq(IDrawEconomics(at).FORGONE_PIPS(), 10_000);
        assertEq(IDrawEconomics(at).MIN_DRAW_FEE_0(), 1);
        assertEq(IDrawEconomics(at).MIN_DRAW_FEE_1(), 2);
    }

    function deployFailsafeAt(bytes memory args, address at) external {
        deployCodeTo("StandingAnchoredHook.sol:StandingAnchoredFailsafeHook", args, at);
    }
}

/// @notice The same ask on the standing failsafe fee hook, where the draw is judged at the fee the swap pays: the
/// module's quote, since a dynamic-fee pool stores none.
contract StandingFailsafeFeeHookAskTest is StandingFailsafeHookTest {
    function setUp() public override {
        super.setUp();
        feeHook = true;
    }
}
