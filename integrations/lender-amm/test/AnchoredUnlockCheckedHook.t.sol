// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RehypoRepeatBase, RehypoRepeatStablePair, RehypoRepeatPricedPair} from "./RehypoSourceRepeat.t.sol";
import {AnchoredUnlockCheckedHook} from "../src/AnchoredUnlockCheckedHook.sol";

interface IAnchoredSource {
    function setFloatBps(uint16 floatBps) external;
    function swapFloat() external view returns (uint256);
    function swapCap() external view returns (uint256);
    function failsafeLeft() external view returns (uint256);
    function float() external view returns (uint256);
}

/// @notice The kit's anchored hooks (`AnchoredUnlockCheckedHook`, `AnchoredFailsafeUnlockCheckedHook`) between keeper
/// moves, on gage's sources: a swap that crosses the anchored range and empties one side's swap float leaves the trade
/// back open until the keeper's next move, in every layout, width and direction; any run of swaps inside the band leaves
/// a swap toward the anchor open after each one, and a round trip back to the anchor gains the trader nothing; an LP's
/// entry or exit between a push and its trade back neither freezes the pool nor pays an LP who also trades. The repeat
/// rounds (`RehypoSourceRepeat.t.sol`) hold the same hooks to the bound across keeper moves.
abstract contract AnchoredHookCases is RehypoRepeatBase {
    /// @dev The declared widths each pair's cases run on: its band's width, a narrow one and the narrowest.
    function _widths() internal pure virtual returns (uint24[3] memory);

    function _hook() internal view returns (AnchoredUnlockCheckedHook) {
        return AnchoredUnlockCheckedHook(payable(address(key.hooks)));
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

    /// @dev A swap toward `limit` naming `amount` (negative for exact input): whether it went through, and what the
    /// trader received of the output token.
    function _trade(int256 amount, uint160 limit) internal returns (bool ok, uint256 out) {
        bool zeroForOne = limit < _price();
        IERC20 outToken = IERC20(zeroForOne ? _token1() : _token0());
        uint256 before = outToken.balanceOf(trader);
        try this.swapExact(zeroForOne, amount, limit) {
            ok = true;
        } catch {}
        out = outToken.balanceOf(trader) - before;
    }

    /// @dev A small amount of the token a swap toward `limit` pays (exact input) or receives (exact output): a whole
    /// USDG, or a hundredth of a whole token0.
    function _small(bool zeroForOne, bool exactOut) internal pure returns (uint256) {
        return zeroForOne == exactOut ? 1e6 : 1e16;
    }

    function _outsideTheRange() internal view returns (bool) {
        uint160 p = _price();
        return p < TickMath.getSqrtPriceAtTick(_hook().getTickLower())
            || p > TickMath.getSqrtPriceAtTick(_hook().getTickUpper());
    }

    /// @dev Whether a small swap toward the anchor, exact input, goes through and pays the trader something (or, from a
    /// hair off the anchor, gets there); the state is left as it was.
    function _wayBackOpen() internal returns (bool open) {
        uint160 c = _centre();
        if (_price() == c) return true;
        uint256 snapshot = vm.snapshotState();
        bool zeroForOne = c < _price();
        (bool ok, uint256 out) = _trade(-int256(_small(zeroForOne, false)), c);
        open = ok && (out > 0 || _price() == c);
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Whether the band's edge on that side lies outside the anchored range, so a push there crosses it.
    function _edgeOutsideTheRange(bool below) internal view returns (bool) {
        uint160 e = _edgePrice(below);
        return below
            ? e < TickMath.getSqrtPriceAtTick(_hook().getTickLower())
            : e > TickMath.getSqrtPriceAtTick(_hook().getTickUpper());
    }

    // ---------------------------------------------------------------- a swap across the range

    /// @dev One stack: the push across the range to the band's edge, three hours with no keeper move, then a small trade
    /// back toward the anchor exact input, one exact output, and the rest of the way to the anchor.
    function _crossAndTradeBack(uint24 declared, uint16 floatOnlyBps, uint16 failsafe, bool below) internal {
        failsafeBps = failsafe;
        _build(Run(declared, floatOnlyBps, 100, 0, 0));
        failsafeBps = 0;
        string memory label = string.concat(
            vm.toString(declared),
            " ticks",
            floatOnlyBps == 10_000 ? ", kit layout" : ", equal targets",
            failsafe == 0 ? "" : ", failsafe hook",
            below ? ", pushed below" : ", pushed above"
        );
        bool crosses = _edgeOutsideTheRange(below);
        (bool pushed,) = _trade(-int256(1e27), _edgePrice(below));
        assertTrue(pushed, label);
        if (crosses) assertTrue(_outsideTheRange(), string.concat(label, ": the push crossed the range"));
        vm.warp(block.timestamp + 3 hours);
        (bool back, uint256 got) = _trade(-int256(_small(!below, false)), _centre());
        assertTrue(back && got > 0, string.concat(label, ": an exact-input trade back fills"));
        (bool backOut, uint256 gotOut) = _trade(int256(_small(!below, true)), _centre());
        assertTrue(backOut && gotOut > 0, string.concat(label, ": an exact-output trade back fills"));
        (bool home,) = _trade(-int256(1e27), _centre());
        assertTrue(home, string.concat(label, ": the rest of the way back"));
        assertEq(_price(), _centre(), string.concat(label, ": back at the anchor"));
    }

    /// @dev Property: after a swap to the band's edge (across the anchored range where the range is narrower than the
    /// band, emptying one side's swap float), a swap back toward the anchor fills, exact input and exact output, hours
    /// later and with no keeper move between, in the kit's layout and with equal targets, at each width, both ways, on
    /// both anchored hooks. Sizing every swap at the anchor afresh froze the pool both ways here until the keeper's next
    /// move.
    function test_aSwapAcrossTheRangeLeavesTheTradeBackOpen() public {
        vm.pauseGasMetering();
        uint24[3] memory widths = _widths();
        uint16[2] memory layouts = [uint16(10_000), 2000];
        uint16[2] memory failsafes = [uint16(0), 1000];
        for (uint256 w; w < 3; ++w) {
            for (uint256 l; l < 2; ++l) {
                for (uint256 f; f < 2; ++f) {
                    for (uint256 d; d < 2; ++d) {
                        uint256 snapshot = vm.snapshotState();
                        _crossAndTradeBack(widths[w], layouts[l], failsafes[f], d == 0);
                        vm.revertToStateAndDelete(snapshot);
                    }
                }
            }
        }
        vm.resumeGasMetering();
    }

    // ---------------------------------------------------------------- any run of swaps between two keeper moves

    /// @dev Property: between two keeper moves, after each swap of any run inside the band (either way, exact input or
    /// exact output, any size, any limit up to the band's edge), a swap toward the anchor goes through and fills; a
    /// trader who then brings the price back to the anchor has gained nothing, valued there: the position holds still
    /// between moves, so a round trip only pays its fees. What the trader gains, the LPs lose (asserted).
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_betweenKeeperMovesTheWayBackStaysOpen(uint256 seed) public {
        vm.pauseGasMetering();
        uint24[3] memory widths = _widths();
        failsafeBps = (seed >> 16) % 2 == 0 ? 0 : 1000;
        _build(Run(widths[seed % 3], (seed >> 8) % 2 == 0 ? 10_000 : 2000, 100, 0, 0));
        failsafeBps = 0;
        int256 t0 = _trader();
        int256 l0 = _lps();
        for (uint256 i; i < 8; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint160 c = _centre();
            uint160 edge = _edgePrice(x % 2 == 0);
            uint256 reach = (x >> 8) % 1001;
            uint160 limit = edge < c
                ? uint160(c - (uint256(c) - edge) * reach / 1000)
                : uint160(c + (uint256(edge) - c) * reach / 1000);
            if (limit == _price()) continue;
            bool zeroForOne = limit < _price();
            bool exactOut = (x >> 24) % 2 == 0;
            // From a hundredth of the small amount to a hundred thousand times it.
            uint256 amount = Math.mulDiv(_small(zeroForOne, exactOut), 1 + (x >> 32) % 10_000_000, 100);
            _trade(exactOut ? int256(amount) : -int256(amount), limit);
            assertTrue(_wayBackOpen(), "a swap toward the anchor goes through and fills");
        }
        if (_price() != _centre()) {
            (bool home,) = _trade(-int256(1e27), _centre());
            assertTrue(home, "the way back to the anchor");
        }
        assertEq(_price(), _centre(), "back at the anchor");
        int256 gain = _trader() - t0;
        assertApproxEqAbs(gain, l0 - _lps(), 1e15 * 10, "the trader's gain is the LPs' loss");
        assertLe(gain, 1e13, "a round trip between keeper moves gains nothing");
        vm.resumeGasMetering();
    }

    // ---------------------------------------------------------------- LP moves between a push and its trade back

    function _sharesValue(address who) internal view returns (int256) {
        (uint256 a0, uint256 a1) = _hook().previewRedeem(_hook().balanceOf(who));
        return _value(a0, a1);
    }

    /// @dev Property: an LP who holds half the shares and exits between a push across the range and its trade back,
    /// then comes back in, gains nothing by it, as trader and LP together: the position the hook holds scales with the
    /// shares, as the sources scale their swap floats, so the trade back is no deeper than what stayed. And a dust
    /// entry there leaves the trade back open.
    function test_anLpMoveBetweenThePushAndTheTradeBack() public {
        vm.pauseGasMetering();
        uint16[2] memory layouts = [uint16(10_000), 2000];
        for (uint256 l; l < 2; ++l) {
            for (uint256 d; d < 2; ++d) {
                uint256 snapshot = vm.snapshotState();
                _exitAroundTheTradeBack(layouts[l], d == 0);
                vm.revertToStateAndDelete(snapshot);
                snapshot = vm.snapshotState();
                _dustEntryAfterThePush(layouts[l], d == 0);
                vm.revertToStateAndDelete(snapshot);
            }
        }
        vm.resumeGasMetering();
    }

    function _exitAroundTheTradeBack(uint16 floatOnlyBps, bool below) internal {
        _build(Run(_widths()[1], floatOnlyBps, 100, 0, 0));
        AnchoredUnlockCheckedHook hook = _hook();
        uint256 half = hook.balanceOf(partner) / 2;
        vm.prank(partner);
        hook.transfer(trader, half);
        int256 start = _trader() + _sharesValue(trader);
        (bool pushed,) = _trade(-int256(1e27), _edgePrice(below));
        assertTrue(pushed && _outsideTheRange(), "the push crossed the range");
        (uint256 out0, uint256 out1) = hook.previewRedeem(half);
        vm.prank(trader);
        hook.removeReHypothecatedLiquidity(half, 0, 0);
        (bool home,) = _trade(-int256(1e27), _centre());
        assertTrue(home, "the trade back after the exit");
        assertEq(_price(), _centre());
        vm.prank(trader);
        hook.addReHypothecatedLiquidity(half * 99 / 100, out0 * 2, out1 * 2);
        assertLe(_trader() + _sharesValue(trader) - start, 1e13, "an exit around the trade back pays nothing");
    }

    function _dustEntryAfterThePush(uint16 floatOnlyBps, bool below) internal {
        _build(Run(_widths()[1], floatOnlyBps, 100, 0, 0));
        (bool pushed,) = _trade(-int256(1e27), _edgePrice(below));
        assertTrue(pushed && _outsideTheRange());
        uint256 dust = _hook().totalSupply() / 1_000_000;
        vm.prank(partner);
        _hook().addReHypothecatedLiquidity(dust, type(uint256).max, type(uint256).max);
        assertTrue(_wayBackOpen(), "a dust entry after the push leaves the trade back open");
    }

    // ---------------------------------------------------------------- the keeper's next move

    /// @dev The keeper's next move sizes the position afresh at the anchor on the swap floats it sets: with both float
    /// targets doubled (a raise applies at once) the move doubles both caps, and the first swap past it holds twice the
    /// liquidity the position held before, where holding still would have kept the old one.
    function test_theKeeperMoveSizesThePositionAfresh() public {
        _build(Run(_widths()[1], 2000, 100, 0, 0));
        (bool tiny,) = _trade(-int256(_small(true, false)), _edgePrice(true));
        assertTrue(tiny);
        uint256 before = _hook().heldLiquidity();
        assertGt(before, 0);
        vm.startPrank(partner);
        IAnchoredSource(address(s0)).setFloatBps(4000);
        IAnchoredSource(address(s1)).setFloatBps(4000);
        vm.stopPrank();
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        (bool next,) = _trade(-int256(_small(true, false)), _edgePrice(true));
        assertTrue(next);
        assertApproxEqRel(_hook().heldLiquidity(), before * 2, 1e16, "sized afresh on the doubled caps");
    }
}

/// @notice The anchored hooks between keeper moves on frxUSD/USDG, and before the first one.
contract AnchoredUnlockCheckedHookStableTest is RehypoRepeatStablePair, AnchoredHookCases {
    function setUp() public override(RehypoRepeatBase, RehypoRepeatStablePair) {
        super.setUp();
    }

    function _widths() internal pure override returns (uint24[3] memory) {
        return [uint24(100), 20, 2];
    }

    /// @dev frxUSD resting at `bps` of parity, as a v4 sqrt price.
    function _at(uint256 bps) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(bps, 1 << 192, 1e4 * 1e12)));
    }

    function _full() internal view returns (bool) {
        return
            _hook().getTickLower() == TickMath.minUsableTick(1) && _hook().getTickUpper() == TickMath.maxUsableTick(1);
    }

    // ---------------------------------------------------------------- before the first keeper move

    /// @dev Property: until both sources hold a cap from a keeper move inside the band, the anchored hook is the full
    /// range; inside the band after both moved, the anchored range; past the band again, the full range.
    function test_theRangeIsFullUntilBothSourcesHaveMoved() public {
        noFirstPass = true;
        _build(Run(20, 2000, 100, 0, 0));
        noFirstPass = false;
        assertTrue(_full(), "before any keeper move");
        vm.prank(keeper);
        s1.rebalance(bandLo, bandHi);
        assertTrue(_full(), "one source moved, not the other");
        vm.prank(keeper);
        s0.rebalance(bandLo, bandHi);
        assertFalse(_full(), "both moved inside the band");
        assertEq(_hook().getTickLower(), _hook().PARITY_TICK() - 10);
        _swapTo(_at(9850));
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        assertTrue(_full(), "past the band");
        _swapTo(_centre());
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        assertFalse(_full(), "back inside the band");
    }

    /// @dev Property: before the first keeper move a drift anywhere inside the band costs the LPs under a quarter of the
    /// smaller side's edge depth (on the anchored range with no cap yet it cost a share of the whole seed), and on the
    /// testnet's +-0.1% range no swap takes more of a side than the cap that first move then sets.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_beforeTheFirstMoveADriftTakesLittle(uint256 drift, bool kitLayout, bool narrow) public {
        uint24 declared = narrow ? 20 : 100;
        fairBps = 9952 + drift % 97;
        noFirstPass = true;
        _build(Run(declared, kitLayout ? 10_000 : 2000, 100, 0, 0));
        noFirstPass = false;
        assertTrue(_full(), "the full range before the first move");
        uint256 snapshot = vm.snapshotState();
        _keeperPass();
        (uint256 cap0, uint256 cap1) = (IAnchoredSource(address(s0)).swapCap(), IAnchoredSource(address(s1)).swapCap());
        vm.revertToStateAndDelete(snapshot);
        uint256 edge = _edge();
        int256 l0 = _lps();
        (uint256 frx0, uint256 usdg0) = (IERC20(_token0()).balanceOf(trader), IERC20(_token1()).balanceOf(trader));
        _swapTo(_fair());
        int256 loss = l0 - _lps();
        assertLt(loss * 4, int256(edge), "under a quarter of the smaller side's edge depth");
        if (narrow) {
            (uint256 frx1, uint256 usdg1) = (IERC20(_token0()).balanceOf(trader), IERC20(_token1()).balanceOf(trader));
            assertLe(frx1 > frx0 ? frx1 - frx0 : 0, cap0, "no more frxUSD than the first move's cap");
            assertLe(usdg1 > usdg0 ? usdg1 - usdg0 : 0, cap1, "no more USDG than the first move's cap");
        }
        fairBps = 10_000;
    }

    // ---------------------------------------------------------------- the anchored failsafe hook's ask

    /// @dev The lent side's float under its cap with the vault's cash back, so the failsafe has room: the stack the ask
    /// cases start from (the keeper's move sets the room, the vault lent everything then, and is repaid since).
    function _roomToDraw() internal returns (uint256 room) {
        failsafeBps = 1000;
        _build(Run(20, 10_000, 100, 0, 0));
        failsafeBps = 0;
        vault.lend(vault.cash());
        uint256 shares = _hook().totalSupply() * 19_700 / 100_000;
        vm.prank(partner);
        _hook().removeReHypothecatedLiquidity(shares, 0, 0);
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        room = IAnchoredSource(address(s1)).failsafeLeft();
        assertGt(room, 0, "the move left the failsafe room");
        uint256 lent = vault.performingPrincipal();
        vm.prank(partner);
        IERC20(_token1()).transfer(address(vault), lent);
        vault.repay(lent, 0);
    }

    /// @dev Property: on a declared range that is not pegged, the float-only side opens its in-band cap and has no
    /// failsafe room, so the anchored failsafe hook asks neither source: a draw on one side alone would deepen
    /// nothing. Not for a swap stopped at the price, however much it names, and not for the first swap past a keeper
    /// move that takes most of the USDG side. (`AnchoredFailsafeAsk.t.sol` proves the ask where both sides have room.)
    function test_theAnchoredFailsafeAsksNothingWhereOneSideHasNoRoom() public {
        vm.pauseGasMetering();
        uint256 room = _roomToDraw();
        assertEq(IAnchoredSource(address(s0)).failsafeLeft(), 0, "the float-only side has no room");
        uint256 snapshot = vm.snapshotState();
        uint256 cash = vault.cash();
        uint160 p = _price();
        (bool dust, uint256 tookDust) = _trade(int256(10_000e6), p - p / 2_000_000);
        assertTrue(dust);
        assertLt(tookDust, 1e6, "a dust fill");
        assertEq(vault.cash(), cash, "a swap stopped at the price draws nothing");
        assertEq(IAnchoredSource(address(s1)).failsafeLeft(), room, "the room stays whole");
        vm.revertToStateAndDelete(snapshot);

        uint256 most = Math.min(IAnchoredSource(address(s1)).float(), IAnchoredSource(address(s1)).swapFloat());
        (bool big,) = _trade(int256(most * 2 / 3), _edgePrice(true));
        assertTrue(big);
        assertEq(vault.cash(), cash, "nor does the first swap past the move, though it takes most of the side");
        assertEq(IAnchoredSource(address(s1)).failsafeLeft(), room, "the room stays whole");
        vm.resumeGasMetering();
    }
}

/// @notice The anchored hooks between keeper moves on NVDA/USDG.
contract AnchoredUnlockCheckedHookPricedTest is RehypoRepeatPricedPair, AnchoredHookCases {
    function setUp() public override(RehypoRepeatBase, RehypoRepeatPricedPair) {
        super.setUp();
    }

    function _widths() internal pure override returns (uint24[3] memory) {
        return [uint24(200), 20, 2];
    }
}
