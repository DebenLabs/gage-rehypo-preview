// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RehypoRepeatPeggedPair} from "./RehypoSourceRepeat.t.sol";

interface IAskSource {
    function failsafeLeft() external view returns (uint256);
    function swapFloat() external view returns (uint256);
}

interface IAskHook {
    function DRAW_TOLERANCE_PIPS() external view returns (uint24);
}

/// @notice The anchored failsafe hooks' ask (`AnchoredFailsafeUnlockCheckedHook._askBoth`), on gage's pegged sources:
/// frxUSD/USDG at one for one on a +-0.25% range, a 10% float either side and a tenth of each side's backing kept free
/// for swaps (the USDG in its vault, the frxUSD, which has no vault, as float it keeps closed). A swap that would move
/// the pool's price more than the tolerance on the floats asks both sources for the same share of what they back, so
/// the position deepens and the swap fills inside the tolerance; the smaller room sets both asks; a swap its own limit
/// stops inside the tolerance, one the float fills, one that would not pay and every swap between two keeper moves ask
/// nothing.
contract AnchoredFailsafeAskTest is RehypoRepeatPeggedPair {
    /// @dev +-0.25%, equal float targets, 0.05% fee.
    uint24 internal constant WIDTH = 50;
    uint24 internal constant FEE = 500;

    function setUp() public override {
        super.setUp();
        failsafeBps = 1000;
        lentBps = 1000;
    }

    function _stack() internal {
        _build(Run(WIDTH, EQUAL, FEE, 0, 0));
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

    /// @dev frxUSD sold with no price limit: what the trader received in USDG.
    function _sell(uint256 frx) internal returns (uint256 got) {
        uint256 before = IERC20(USDG).balanceOf(trader);
        this.swapExact(true, -int256(frx), TickMath.MIN_SQRT_PRICE + 1);
        got = IERC20(USDG).balanceOf(trader) - before;
    }

    function _room0() internal view returns (uint256) {
        return IAskSource(address(s0)).failsafeLeft();
    }

    function _room1() internal view returns (uint256) {
        return IAskSource(address(s1)).failsafeLeft();
    }

    /// @dev The pool's price as a share of `from`, in millionths of the price (a sqrt price, squared).
    function _movedTo(uint160 from) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(_price(), 1e6, from), _price(), from);
    }

    function test_theStackKeepsATenthOpenAndATenthFreeEitherSide() public {
        _stack();
        assertEq(IAskHook(address(key.hooks)).DRAW_TOLERANCE_PIPS(), 500);
        assertApproxEqAbs(s0.swapFloat(), 10_000e18, 1e12, "frxUSD: a tenth open");
        assertApproxEqAbs(s1.swapFloat(), 10_000e6, 1, "USDG: a tenth open");
        assertApproxEqAbs(_room0(), 10_000e18, 1e12, "frxUSD: a tenth more may open, from the float it keeps closed");
        assertApproxEqAbs(_room1(), 10_000e6, 1, "USDG: a tenth more may come from the vault's free cash");
    }

    /// @dev The floats back about 1,925 USDG inside 0.05%: a 1,500 frxUSD sale asks nothing.
    function test_aSwapTheFloatsFillInsideTheToleranceAsksNothing() public {
        _stack();
        (uint256 room0, uint256 room1, uint256 cash) = (_room0(), _room1(), vault.cash());
        uint160 p = _price();
        _sell(1500e18);
        assertEq(_room0(), room0);
        assertEq(_room1(), room1);
        assertEq(vault.cash(), cash, "no vault call");
        assertGe(_movedTo(p), 1e6 - 500, "inside the tolerance on the floats alone");
    }

    /// @dev A 3,000 frxUSD sale needs over half as much liquidity again: both sources give the same share of what they
    /// back, the swap ends inside the tolerance, and the trader gets more than on the floats alone.
    function test_aSwapPastTheToleranceDrawsBothCoinsInStep() public {
        uint256 snapshot = vm.snapshotState();
        failsafeBps = 0;
        _stack();
        uint160 start = _price();
        uint256 plain = _sell(3000e18);
        uint256 plainMove = _movedTo(start);
        assertLt(plainMove, 1e6 - 500, "on the floats alone the sale moves the price past the tolerance");
        vm.revertToStateAndDelete(snapshot);

        _stack();
        (uint256 room0, uint256 room1, uint256 cash) = (_room0(), _room1(), vault.cash());
        start = _price();
        uint256 got = _sell(3000e18);
        (uint256 drew0, uint256 drew1) = (room0 - _room0(), room1 - _room1());
        // The floats back about 1,925 USDG inside the tolerance (the pool's price rests a tick above the anchor's own),
        // so the sale needs about 56% more liquidity: that share of the 10,000 USDG the float backs.
        assertApproxEqRel(drew1, 5570e6, 0.01e18, "the share that lets the sale fill inside the tolerance");
        assertApproxEqRel(drew0 / 1e12, drew1, 0.001e18, "the same share of the frxUSD, from the float it kept closed");
        assertEq(cash - vault.cash(), drew1, "the USDG from the vault's free cash, inside the swap");
        assertGe(_movedTo(start), 1e6 - 501, "the sale ends inside the tolerance");
        assertGt(_movedTo(start), plainMove);
        assertGt(got, plain, "and pays the trader more");
    }

    /// @dev The other way: USDG sold for frxUSD draws both the same.
    function test_buyingTheOtherCoinAsksTheSame() public {
        _stack();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        uint160 start = _price();
        this.swapExact(false, -int256(3000e6), TickMath.MAX_SQRT_PRICE - 1);
        (uint256 drew0, uint256 drew1) = (room0 - _room0(), room1 - _room1());
        assertApproxEqRel(drew0, 5580e18, 0.01e18, "the share that lets the buy fill inside the tolerance");
        assertApproxEqRel(drew1, drew0 / 1e12, 0.001e18);
        assertLe(_movedTo(start), 1e6 + 501, "the buy ends inside the tolerance");
    }

    /// @dev A sale far larger than both rooms: each source gives its room and no more.
    function test_neverMoreThanEachSourcesRoom() public {
        _stack();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        _sell(15_000e18);
        assertEq(_room0(), 0, "all of the frxUSD room");
        assertLe(_room1(), 1, "all of the USDG room, to a rounding of the step");
        assertApproxEqAbs(
            s0.swapFloat(), 10_000e18 + room0 + 15_000e18, 1e13, "the float, the draw and the sale's input"
        );
        assertLt(s1.swapFloat(), 10_000e6 + room1);
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

    /// @dev A sale that names 15,000 frxUSD and stops 0.03% under the price takes what the floats give there and asks
    /// nothing; stopped past the tolerance, it asks.
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

    /// @dev Between two keeper moves the position stands as the first swap left it: a later swap asks nothing, however
    /// large, and the first swap after the next move asks again.
    function test_betweenKeeperMovesOnlyTheSwapThatSizesThePositionAsks() public {
        _stack();
        (uint256 room0, uint256 room1) = (_room0(), _room1());
        _sell(500e18);
        _sell(3000e18);
        assertEq(_room0(), room0, "held: no ask");
        assertEq(_room1(), room1);
        this.swapExact(false, -int256(1e27), _centre());
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        (room0, room1) = (_room0(), _room1());
        _sell(3000e18);
        assertLt(_room0(), room0, "sized afresh: it asks");
        assertLt(_room1(), room1);
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
        _build(Run(WIDTH, EQUAL, 3000, 0, 0));
        room1 = _room1();
        _sell(3000e18);
        assertLt(_room1(), room1, "at 0.3% it does");
    }

    /// @dev On the fee hook the pool stores no fee: the draw is judged at the fee the swap pays, the module's quote.
    function test_onTheFeeHookTheDrawIsJudgedAtTheFeeTheSwapPays() public {
        feeHook = true;
        drawFee1 = 5e6;
        uint256 snapshot = vm.snapshotState();
        _stack();
        uint256 room1 = _room1();
        _sell(3000e18);
        assertEq(_room1(), room1, "at the module's 0.05% it does not pay");
        vm.revertToStateAndDelete(snapshot);
        _build(Run(WIDTH, EQUAL, 3000, 0, 0));
        (uint256 room0, uint256 cash) = (_room0(), vault.cash());
        room1 = _room1();
        _sell(3000e18);
        assertLt(_room1(), room1, "at the module's 0.3% it does");
        assertLt(_room0(), room0, "both coins");
        assertEq(cash - vault.cash(), room1 - _room1());
    }
}
