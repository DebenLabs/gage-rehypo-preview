// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {AnchoredUnlockCheckedHook} from "../src/AnchoredUnlockCheckedHook.sol";
import {UnlockCheckedHook} from "../src/UnlockCheckedHook.sol";
import {StandingPosition} from "../src/StandingAnchoredHook.sol";
import {RehypoRepeatBase} from "./RehypoSourceRepeat.t.sol";
import {StandingBase, StandingPeggedPair, StandingStablePair, Unlocker} from "./utils/StandingFixture.sol";

interface IStandingSource {
    function swapFloat() external view returns (uint256);
    function centre() external view returns (uint160);
}

/// @notice The cases every pair's standing hook is held to: what a swap, a keeper move, an LP move and a take-out do
/// to the position the hook leaves in the pool, and to the LPs' backing.
abstract contract StandingHookCases is StandingBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev VaultSettling(), gage's source refusing a move between a loan's end and its settle.
    bytes4 internal constant VAULT_SETTLING = bytes4(keccak256("VaultSettling()"));

    function _run() internal pure virtual returns (Run memory);

    /// @dev The stack after its first keeper move and the first swap after it, which places the position; with
    /// `noFirstPass`, as the seed leaves it.
    function _stack() internal {
        _buildStanding(_run());
        if (!noFirstPass) _dustSwap();
    }

    /// @dev The position as the PoolManager records it for the hook on [`lower`, `upper`].
    function _inThePool(int24 lower, int24 upper) internal view returns (uint128) {
        return pm.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(key.hooks), lower, upper, bytes32(0))
        );
    }

    // ---------------------------------------------------------------- placing

    /// @dev The keeper's pass leaves the position out of the pool, everything in the sources. The first swap after it
    /// places the position on the anchored range, sized as the anchored hook sizes its first swap after the same pass,
    /// and pays for the placing; the next swap finds it in place. The hook is asked for nothing after a swap.
    function test_theFirstSwapAfterAKeeperMovePlacesThePosition() public {
        Run memory r = _run();
        uint256 snapshot = vm.snapshotState();
        _buildAnchored(r);
        this.swapExact(true, -1, _price() - 1);
        uint256 jit = AnchoredUnlockCheckedHook(payable(address(key.hooks))).heldLiquidity();
        vm.revertToStateAndDelete(snapshot);

        _buildStanding(r);
        StandingPosition hook = _hook();
        assertEq(_liquidity(), 0, "the keeper's pass places nothing");
        (uint256 seed0, uint256 seed1) = _seed();
        assertApproxEqAbs(s0.totalAssets(), seed0, 2, "everything is in the sources");
        assertApproxEqAbs(s1.totalAssets(), seed1, 2);

        vm.startStateDiffRecording();
        _dustSwap();
        assertGt(_sourceAccesses(vm.stopAndReturnStateDiff()), 0, "the first swap pays for the placing");
        (uint128 liquidity, int24 lower, int24 upper) = hook.position();
        assertGt(liquidity, 0, "placed by the first swap");
        assertEq(lower, hook.getTickLower(), "on the anchored range");
        assertEq(upper, hook.getTickUpper());
        assertEq(upper - lower, int24(r.declared));
        assertEq(_inThePool(lower, upper), liquidity, "in the pool");
        assertApproxEqRel(liquidity, jit, 1e9, "the liquidity the anchored hook's first swap holds");
        (uint256 a0, uint256 a1) = hook.positionAmounts();
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertApproxEqAbs(s0.totalAssets() + a0, seed0, 4, "what the position holds left the source's count");
        assertApproxEqAbs(s1.totalAssets() + a1, seed1, 4);

        vm.startStateDiffRecording();
        _dustSwap();
        assertEq(_sourceAccesses(vm.stopAndReturnStateDiff()), 0, "the next swap finds it in place");
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.beforeInitialize && p.beforeAddLiquidity && p.beforeRemoveLiquidity);
        assertFalse(p.afterSwap, "nothing to do after a swap");
    }

    /// @dev Before the first keeper move the first swap places the position on the full range; the pass then moves it
    /// to the anchored range.
    function test_beforeTheFirstMoveTheFirstSwapPlacesTheFullRange() public {
        noFirstPass = true;
        _stack();
        noFirstPass = false;
        assertEq(_liquidity(), 0, "nothing placed at the seed");
        (bool ok, uint256 out) = _trade(-int256(_small(true)), _edgePrice(true));
        assertTrue(ok && out > 0);
        (uint128 liquidity, int24 lower, int24 upper) = _hook().position();
        assertGt(liquidity, 0);
        assertEq(lower, TickMath.minUsableTick(1));
        assertEq(upper, TickMath.maxUsableTick(1));
        _pass();
        assertEq(_liquidity(), 0, "the pass takes the full range out and places nothing");
        _dustSwap();
        (, lower, upper) = _hook().position();
        assertEq(upper - lower, int24(_run().declared), "the first swap after the pass places the anchored range");
    }

    // ---------------------------------------------------------------- a swap on a placed position

    /// @dev A swap that finds the position in place touches neither source nor the vault; the swap that has to place
    /// it (here after a holder took it out) does.
    function test_aSwapOnAPlacedPositionCallsNoSource() public {
        _stack();
        uint128 liquidity = _liquidity();
        vm.startStateDiffRecording();
        (bool down, uint256 got) = _trade(-int256(_small(true) * 100), _edgePrice(true));
        (bool up, uint256 back) = _trade(-int256(_small(false) * 50), _edgePrice(false));
        Vm.AccountAccess[] memory placed = vm.stopAndReturnStateDiff();
        assertTrue(down && got > 0 && up && back > 0, "both swaps fill");
        assertEq(_sourceAccesses(placed), 0, "no call to a source or the vault");
        assertEq(_liquidity(), liquidity, "the position stays as it was");

        _holderTakesOut();
        vm.startStateDiffRecording();
        (down,) = _trade(-int256(_small(true)), _edgePrice(true));
        Vm.AccountAccess[] memory placing = vm.stopAndReturnStateDiff();
        assertTrue(down);
        assertGt(_sourceAccesses(placing), 0, "the swap that places the position pays for it through the sources");
    }

    /// @dev The same swap on the anchored hook and on a placed standing position, and a keeper's pass on each: logged,
    /// and the standing swap under half the anchored one.
    function test_gas_aSwapOnAPlacedPositionAgainstTheAnchoredHook() public {
        Run memory r = _run();
        int256 amount = -int256(_small(true) * 100);
        uint256 snapshot = vm.snapshotState();
        _buildAnchored(r);
        this.swapExact(true, amount, _edgePrice(true));
        uint256 anchored = _swapGas(true, amount, _edgePrice(true));
        vm.warp(block.timestamp + 5 minutes);
        bytes memory move = _moveData();
        vm.startPrank(keeper);
        (bool ok0,) = address(s0).call(move);
        uint256 passAnchored = vm.lastCallGas().gasTotalUsed;
        (bool ok1,) = address(s1).call(move);
        passAnchored += vm.lastCallGas().gasTotalUsed;
        vm.stopPrank();
        assertTrue(ok0 && ok1);
        vm.revertToStateAndDelete(snapshot);

        _stack();
        this.swapExact(true, amount, _edgePrice(true));
        uint256 standing = _swapGas(true, amount, _edgePrice(true));
        vm.warp(block.timestamp + 5 minutes);
        move = _moveData();
        vm.prank(keeper);
        (bool ok,) = address(key.hooks).call(move);
        uint256 passStanding = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok);
        _holderTakesOut();
        uint256 placing = _swapGas(true, amount, _edgePrice(true));

        console2.log("swap through the test router, anchored hook (gas):", anchored);
        console2.log("swap through the test router, standing position in place (gas):", standing);
        console2.log("swap that places the position, standing hook (gas):", placing);
        console2.log("keeper pass, both sources called directly (gas):", passAnchored);
        console2.log("keeper pass through the standing hook: take out, both moves (gas):", passStanding);
        assertLt(standing * 2, anchored, "under half the anchored hook's swap");
    }

    /// @dev Between two keeper moves the standing position fills every swap as the anchored hook does: the same
    /// swaps, there and back, pay the trader the same.
    function test_betweenKeeperMovesItFillsAsTheAnchoredHookDoes() public {
        Run memory r = _run();
        uint256[4] memory jit;
        uint256[4] memory standing;
        uint256 snapshot = vm.snapshotState();
        _buildAnchored(r);
        jit = _fourSwaps();
        vm.revertToStateAndDelete(snapshot);
        _stack();
        standing = _fourSwaps();
        for (uint256 i; i < 4; ++i) {
            assertGt(standing[i], 0);
            assertApproxEqRel(standing[i], jit[i], 1e12, "the same fill");
        }
    }

    function _fourSwaps() internal returns (uint256[4] memory out) {
        (, out[0]) = _trade(-int256(_small(true) * 100), _edgePrice(true));
        (, out[1]) = _trade(-int256(_small(true) * 300), _edgePrice(true));
        (, out[2]) = _trade(-int256(_small(false) * 500), _edgePrice(false));
        (, out[3]) = _trade(int256(_small(true) * 50), _edgePrice(false));
    }

    /// @dev About a dollar of the token a swap that way pays in.
    function _small(bool zeroForOne) internal view virtual returns (uint256);

    /// @dev One swap of a run drawn from `seed`: either way, exact input or exact output, from a cent to a hundred
    /// thousand dollars, to any limit up to the band's edge. Whether it went through, and what the trader received.
    function _drawnSwap(uint256 seed, uint256 i) internal returns (bool ok, uint256 out) {
        uint256 x = uint256(keccak256(abi.encode(seed, i)));
        uint160 c = _centre();
        uint160 edge = _edgePrice(x % 2 == 0);
        uint256 reach = (x >> 8) % 1001;
        uint160 limit = edge < c
            ? uint160(c - (uint256(c) - edge) * reach / 1000)
            : uint160(c + (uint256(edge) - c) * reach / 1000);
        if (limit == _price()) return (false, 0);
        bool zeroForOne = limit < _price();
        bool exactOut = (x >> 24) % 2 == 0;
        uint256 amount = _small(zeroForOne != exactOut) * (1 + (x >> 32) % 10_000_000) / 100;
        return _trade(exactOut ? int256(amount) : -int256(amount), limit);
    }

    /// @dev Property: between two keeper moves, any run of swaps fills on the standing position as it fills on the
    /// anchored hook, swap for swap: the same ones go through, and each pays the trader the same.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_betweenKeeperMovesItFillsAsTheAnchoredHookDoes(uint256 seed) public {
        vm.pauseGasMetering();
        Run memory r = _run();
        bool[8] memory went;
        uint256[8] memory paid;
        uint256 snapshot = vm.snapshotState();
        _buildAnchored(r);
        for (uint256 i; i < 8; ++i) {
            (went[i], paid[i]) = _drawnSwap(seed, i);
        }
        uint160 last = _price();
        vm.revertToStateAndDelete(snapshot);
        _stack();
        for (uint256 i; i < 8; ++i) {
            (bool ok, uint256 out) = _drawnSwap(seed, i);
            assertEq(ok, went[i], "the same swaps go through");
            assertApproxEqRel(out, paid[i], 1e12, "and pay the same");
        }
        assertApproxEqRel(_price(), last, 1e9, "to the same price");
        vm.resumeGasMetering();
    }

    // ---------------------------------------------------------------- taking out and placing again

    /// @dev What `shares` redeem and the LPs' backing, both coins.
    struct Worth {
        uint256 redeem0;
        uint256 redeem1;
        uint256 backing0;
        uint256 backing1;
    }

    function _worth(uint256 shares) internal view returns (Worth memory w) {
        (w.redeem0, w.redeem1) = _redeems(shares);
        (w.backing0, w.backing1) = _backing();
    }

    function _assertWorth(Worth memory a, Worth memory b, uint256 within, string memory when) internal pure {
        assertApproxEqAbs(a.redeem0, b.redeem0, within, string.concat("token0 a share redeems, ", when));
        assertApproxEqAbs(a.redeem1, b.redeem1, within, string.concat("token1 a share redeems, ", when));
        assertApproxEqAbs(a.backing0, b.backing0, within, string.concat("token0 backing, ", when));
        assertApproxEqAbs(a.backing1, b.backing1, within, string.concat("token1 backing, ", when));
    }

    /// @dev Taking the position out and placing it again, with fees in it and the price off the anchor, moves no LP's
    /// share value and leaves the same liquidity (less a raw unit's worth where the amounts round).
    function test_takingOutAndPlacingAgainMovesNoValue() public {
        _stack();
        _trade(-int256(_small(true) * 5000), _edgePrice(true));
        StandingPosition hook = _hook();
        uint256 shares = hook.balanceOf(partner);
        (uint128 liquidity, int24 lower, int24 upper) = hook.position();
        Worth memory before = _worth(shares);

        _holderTakesOut();
        assertEq(_liquidity(), 0, "out");
        assertEq(_inThePool(lower, upper), 0, "nothing left in the pool");
        (uint256 p0, uint256 p1) = hook.positionAmounts();
        assertEq(p0 + p1, 0);
        assertEq(IERC20(_token0()).balanceOf(address(hook)) + IERC20(_token1()).balanceOf(address(hook)), 0);
        assertEq(hook.heldLiquidity(), liquidity, "held for the next placing");
        _assertWorth(_worth(shares), before, 5, "out");

        _dustSwap();
        (uint128 again, int24 lowerAgain, int24 upperAgain) = hook.position();
        assertApproxEqRel(again, liquidity, 1e9, "the same liquidity");
        assertLe(again, liquidity, "never more");
        assertEq(lowerAgain, lower);
        assertEq(upperAgain, upper);
        _assertWorth(_worth(shares), before, 10, "placed again");
    }

    /// @dev Taking out with nothing placed does nothing, for a keeper and a holder alike.
    function test_takingOutTwiceDoesNothing() public {
        _stack();
        _holderTakesOut();
        (uint256 b0, uint256 b1) = _backing();
        _holderTakesOut();
        vm.prank(keeper);
        _hook().takeOut();
        (uint256 c0, uint256 c1) = _backing();
        assertEq(c0, b0);
        assertEq(c1, b1);
    }

    // ---------------------------------------------------------------- the backing

    uint256 private _all0;
    uint256 private _all1;
    uint256 private _steps;

    /// @dev Everything the partner and the trader hold beside the LPs' backing: constant but for what a rounding
    /// leaves in the PoolManager, a raw unit of each amount and, of an 18-decimal token0, the few hundred raw units
    /// one unit of the pool's sqrt price is worth across the position.
    function _everything() internal view returns (uint256 e0, uint256 e1) {
        (uint256 b0, uint256 b1) = _backing();
        e0 = b0 + IERC20(_token0()).balanceOf(partner) + IERC20(_token0()).balanceOf(trader);
        e1 = b1 + IERC20(_token1()).balanceOf(partner) + IERC20(_token1()).balanceOf(trader);
    }

    function _checkBacking(string memory when) internal {
        (uint256 e0, uint256 e1) = _everything();
        ++_steps;
        assertApproxEqAbs(e0, _all0, 1e4 * _steps, string.concat("token0 backing after ", when));
        assertApproxEqAbs(e1, _all1, 4 * _steps, string.concat("token1 backing after ", when));
        assertLe(e0, _all0, "rounding never favours the LPs' count");
        assertLe(e1, _all1);
    }

    /// @dev The position's amounts and both sources' `totalAssets` are the LPs' backing after every action: what the
    /// trader and the LPs paid in less what they took out, to a few raw units of rounding an action.
    function test_thePositionAndBothSourcesAreTheBacking() public {
        noFirstPass = true;
        _stack();
        noFirstPass = false;
        StandingPosition hook = _hook();
        (_all0, _all1) = _everything();
        (uint256 seed0, uint256 seed1) = _seed();
        (uint256 b0, uint256 b1) = _backing();
        assertEq(b0, seed0, "the seed");
        assertEq(b1, seed1);

        _pass();
        _checkBacking("the first keeper move");
        _trade(-int256(_small(true) * 2000), _edgePrice(true));
        _checkBacking("a swap");
        _trade(-int256(_small(false) * 5000), _edgePrice(false));
        _checkBacking("a swap back");
        uint256 shares = hook.totalSupply() / 10;
        vm.prank(trader);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        _checkBacking("an LP entry");
        _trade(-int256(_small(true) * 50), _edgePrice(true));
        _checkBacking("the swap that places it again");
        shares = hook.balanceOf(partner) / 4;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        _checkBacking("an LP exit");
        _trade(-int256(1e27), _edgePrice(true));
        _checkBacking("a push to the band's edge");
        _holderTakesOut();
        _checkBacking("a take-out");
        _trade(-int256(_small(false) * 20), _centre());
        _checkBacking("a swap after the take-out");
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        _checkBacking("a keeper move");
        _trade(-int256(1e27), _centre());
        _checkBacking("the trade back");
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        _checkBacking("the next keeper move");
        (b0, b1) = hook.previewRedeem(hook.totalSupply());
        (uint256 c0, uint256 c1) = _backing();
        assertApproxEqAbs(b0, c0, c0 / 1e6, "every share redeems the backing, less the virtual shares' part");
        assertApproxEqAbs(b1, c1, c1 / 1e6 + 1);
    }

    /// @dev Property: the same after every action of any run of them: a swap either way, a keeper's move, an LP entry,
    /// an LP exit, a take-out.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_thePositionAndBothSourcesAreTheBacking(uint256 seed) public {
        vm.pauseGasMetering();
        _stack();
        StandingPosition hook = _hook();
        (_all0, _all1) = _everything();
        for (uint256 i; i < 12; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i, "action"))) % 8;
            if (x < 4) {
                _drawnSwap(seed, i);
            } else if (x == 4) {
                vm.warp(block.timestamp + 5 minutes);
                _pass();
            } else if (x == 5) {
                uint256 shares = hook.totalSupply() / (2 + seed % 50);
                vm.prank(trader);
                hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
            } else if (x == 6) {
                uint256 shares = hook.balanceOf(partner) / (2 + (seed >> 8) % 50);
                vm.prank(partner);
                hook.removeReHypothecatedLiquidity(shares, 0, 0);
            } else {
                _holderTakesOut();
            }
            _checkBacking(string.concat("action ", vm.toString(x), " at step ", vm.toString(i)));
        }
        vm.resumeGasMetering();
    }

    // ---------------------------------------------------------------- LP moves

    function _balances(address who) internal view returns (uint256, uint256) {
        return (IERC20(_token0()).balanceOf(who), IERC20(_token1()).balanceOf(who));
    }

    /// @dev The trader enters with `shares`: what it paid, the hook's quote with the position counted and its part of
    /// the fees the position has not collected yet, which the quote leaves out.
    function _enter(uint256 shares) internal returns (uint256 paid0, uint256 paid1) {
        (uint256 q0, uint256 q1) = _hook().previewMint(shares);
        (uint256 f0, uint256 f1) = _feeShare(shares);
        (uint256 t0, uint256 t1) = _balances(trader);
        vm.prank(trader);
        _hook().addReHypothecatedLiquidity(shares, q0 + f0 + 5, q1 + f1 + 5);
        (paid0, paid1) = _balances(trader);
        (paid0, paid1) = (t0 - paid0, t1 - paid1);
        assertApproxEqAbs(paid0, q0 + f0, 5, "the entry pays the quote and its part of the uncollected fees");
        assertApproxEqAbs(paid1, q1 + f1, 5);
    }

    /// @dev The trader leaves with `shares`: what it got, the hook's quote and its part of the uncollected fees.
    function _leave(uint256 shares) internal returns (uint256 got0, uint256 got1) {
        (uint256 r0, uint256 r1) = _hook().previewRedeem(shares);
        (uint256 f0, uint256 f1) = _feeShare(shares);
        (uint256 t0, uint256 t1) = _balances(trader);
        vm.prank(trader);
        _hook().removeReHypothecatedLiquidity(shares, r0 > 5 ? r0 - 5 : 0, r1 > 5 ? r1 - 5 : 0);
        (got0, got1) = _balances(trader);
        (got0, got1) = (got0 - t0, got1 - t1);
        assertApproxEqAbs(got0, r0 + f0, 5, "the exit pays the quote and its part of the uncollected fees");
        assertApproxEqAbs(got1, r1 + f1, 5);
    }

    /// @dev An LP entry and exit with the position in the pool: the entry pays what the hook quoted with the position
    /// counted, takes the position out, and leaves the next swap to place it at the held liquidity scaled by the
    /// shares; so does the exit; neither moves the other LP's share value, and the round trip gains nothing.
    function _entryAndExit(uint8 where) internal {
        _stack();
        if (where == 1) _trade(-int256(_small(true) * 5000), _edgePrice(true));
        if (where == 2) _trade(-int256(1e27), _edgePrice(true));
        StandingPosition hook = _hook();
        uint256 liquidity = _liquidity();
        assertGt(liquidity, 0);
        uint256 held = hook.balanceOf(partner);
        uint256 shares = hook.totalSupply() / 10;
        (uint256 v0, uint256 v1) = _redeems(held);

        (uint256 paid0, uint256 paid1) = _enter(shares);
        assertEq(_liquidity(), 0, "the entry took the position out");
        assertApproxEqRel(hook.heldLiquidity(), liquidity * 11 / 10, 1e9, "held, scaled by the shares");
        (uint256 w0, uint256 w1) = _redeems(held);
        assertApproxEqAbs(w0, v0, 10, "the other LP's token0 unmoved by the entry");
        assertApproxEqAbs(w1, v1, 10);
        assertGe(w0 + 5, v0, "never diluted");
        assertGe(w1 + 5, v1);

        _dustSwap();
        assertApproxEqRel(_liquidity(), liquidity * 11 / 10, 1e9, "placed again at the scaled liquidity");
        assertLe(_liquidity(), liquidity * 11 / 10 + 1, "never sized afresh");

        (uint256 got0, uint256 got1) = _leave(shares);
        assertLe(got0, paid0 + 2, "the round trip gains no token0");
        assertLe(got1, paid1 + 2, "nor token1");
        assertEq(_liquidity(), 0, "the exit took the position out");
        (w0, w1) = _redeems(held);
        assertApproxEqAbs(w0, v0, 20, "the other LP's token0 unmoved by the exit");
        assertApproxEqAbs(w1, v1, 20);

        _dustSwap();
        assertApproxEqRel(_liquidity(), liquidity, 1e9, "placed again at the liquidity it had");
        assertLe(_liquidity(), liquidity);
    }

    function test_anLpEntryAndExitAtTheAnchor() public {
        _entryAndExit(0);
    }

    function test_anLpEntryAndExitOffTheAnchor() public {
        _entryAndExit(1);
    }

    function test_anLpEntryAndExitPastTheRange() public {
        _entryAndExit(2);
    }

    /// @dev No LP move, and no take-out, from inside a PoolManager unlock.
    function test_lpMovesRevertInsideAnUnlock() public {
        _stack();
        StandingPosition hook = _hook();
        Unlocker inside = new Unlocker(pm);
        uint256 some = hook.totalSupply() / 100;
        vm.prank(partner);
        hook.transfer(address(inside), some);
        bytes4 refused = UnlockCheckedHook.LiquidityChangeInsideUnlock.selector;
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.addReHypothecatedLiquidity, (1e9, 1e30, 1e30)));
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.removeReHypothecatedLiquidity, (1e9, 0, 0)));
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.seedLiquidity, (1e18, 1e6)));
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.takeOut, ()));
        // With the position out too.
        _holderTakesOut();
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.addReHypothecatedLiquidity, (1e9, 1e30, 1e30)));
        vm.expectRevert(refused);
        inside.callInsideUnlock(address(hook), abi.encodeCall(hook.removeReHypothecatedLiquidity, (1e9, 0, 0)));
        // Nor a keeper's move.
        vm.prank(partner);
        hook.setKeeper(address(inside), true);
        vm.expectRevert();
        inside.callInsideUnlock(address(hook), _moveData());
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        vm.expectRevert();
        inside.callInsideUnlock(address(hook), _moveData());
    }

    // ---------------------------------------------------------------- the keeper's move

    /// @dev One call takes the position out and moves both sources; the first swap after it places the position
    /// afresh on what they then open.
    function test_theKeeperMoveTakesThePositionOutAndTheNextSwapSizesItAfresh() public {
        _stack();
        uint128 before = _liquidity();
        (uint256 b0, uint256 b1) = _backing();
        vm.startPrank(partner);
        IFloatTarget(address(s0)).setFloatBps(s0.floatBps() * 2);
        IFloatTarget(address(s1)).setFloatBps(s1.floatBps() * 2);
        vm.stopPrank();
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        assertEq(_liquidity(), 0, "the move leaves the position out");
        (uint256 a0, uint256 a1) = _hook().positionAmounts();
        assertEq(a0 + a1, 0);
        assertApproxEqAbs(s0.totalAssets(), b0, 1e4, "everything is in the sources");
        assertApproxEqAbs(s1.totalAssets(), b1, 2);
        _dustSwap();
        assertApproxEqRel(_liquidity(), uint256(before) * 2, 1e16, "sized afresh on the doubled float targets");
    }

    /// @dev The same keeper move on a standing hook costs the keeper less than half what placing in it would: logged
    /// beside the first swap after it, which pays for the placing, and the swap after that.
    function test_gas_theKeeperMoveAndTheSwapThatPlaces() public {
        _stack();
        _trade(-int256(_small(true) * 100), _edgePrice(true));
        vm.warp(block.timestamp + 5 minutes);
        bytes memory move = _moveData();
        vm.prank(keeper);
        (bool ok,) = address(key.hooks).call(move);
        assertTrue(ok);
        uint256 moveGas = vm.lastCallGas().gasTotalUsed;
        uint256 placing = _swapGas(true, -int256(_small(true)), _edgePrice(true));
        uint256 placed = _swapGas(true, -int256(_small(true)), _edgePrice(true));
        emit log_named_uint("keeper move through the hook, position taken out", moveGas);
        emit log_named_uint("first swap after it, placing the position", placing);
        emit log_named_uint("next swap, position in place", placed);
        assertLt(placed * 2, placing, "only the first swap pays for the placing");
    }

    /// @dev A move the second source refuses (its vault between a loan's end and its settle) reverts whole: the
    /// position, both swap floats and the first source's move are as they were.
    function test_aKeeperMoveASourceRefusesLeavesThePositionUntouched() public {
        _stack();
        _trade(-int256(_small(true) * 100), _edgePrice(true));
        (uint128 liquidity, int24 lower, int24 upper) = _hook().position();
        (uint256 a0, uint256 a1) = _hook().positionAmounts();
        uint256 float0 = IStandingSource(address(s0)).swapFloat();
        uint256 float1 = IStandingSource(address(s1)).swapFloat();
        (uint256 b0, uint256 b1) = _backing();

        vm.warp(block.timestamp + 5 minutes);
        vault.setEarliestMaturity(uint40(block.timestamp));
        bytes memory move = _moveData();
        vm.expectRevert(VAULT_SETTLING);
        vm.prank(keeper);
        (bool ok,) = address(key.hooks).call(move);
        ok;

        (uint128 liquidityAfter, int24 lowerAfter, int24 upperAfter) = _hook().position();
        assertEq(liquidityAfter, liquidity, "the position stays");
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
        assertEq(_inThePool(lower, upper), liquidity, "in the pool");
        (uint256 c0, uint256 c1) = _hook().positionAmounts();
        assertEq(c0, a0);
        assertEq(c1, a1);
        assertEq(IStandingSource(address(s0)).swapFloat(), float0, "the first source's move is undone");
        assertEq(IStandingSource(address(s1)).swapFloat(), float1);
        (c0, c1) = _backing();
        assertEq(c0, b0);
        assertEq(c1, b1);
        (bool fills, uint256 out) = _trade(-int256(_small(true)), _edgePrice(true));
        assertTrue(fills && out > 0, "and still fills swaps");
    }

    // ---------------------------------------------------------------- who may do what

    function test_onlyKeepersAndLpHoldersTakeThePositionOut() public {
        _stack();
        StandingPosition hook = _hook();
        vm.expectRevert(StandingPosition.NotKeeperOrHolder.selector);
        vm.prank(stranger);
        hook.takeOut();
        vm.expectRevert(StandingPosition.NotKeeperOrHolder.selector);
        vm.prank(trader);
        hook.takeOut();
        assertGt(_liquidity(), 0);

        vm.prank(keeper);
        hook.takeOut();
        assertEq(_liquidity(), 0, "a keeper takes it out");
        _dustSwap();
        assertGt(_liquidity(), 0);

        vm.prank(partner);
        hook.transfer(stranger, 1);
        vm.prank(stranger);
        hook.takeOut();
        assertEq(_liquidity(), 0, "an LP-share holder takes it out");
    }

    function test_onlyKeepersMoveAndOnlyTheSourcesOwnerNamesThem() public {
        _stack();
        StandingPosition hook = _hook();
        bytes memory move = _moveData();
        address[2] memory others = [stranger, partner];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(StandingPosition.NotKeeper.selector);
            vm.prank(others[i]);
            (bool ok,) = address(hook).call(move);
            ok;
            vm.expectRevert(StandingPosition.NotKeeper.selector);
            vm.prank(others[i]);
            hook.rebalance(1, 2);
            vm.expectRevert(StandingPosition.NotKeeper.selector);
            vm.prank(others[i]);
            hook.rebalanceAt("");
        }
        vm.expectRevert(StandingPosition.NotSourceOwner.selector);
        vm.prank(keeper);
        hook.setKeeper(stranger, true);
        vm.expectRevert(StandingPosition.NotSourceOwner.selector);
        vm.prank(stranger);
        hook.setKeeper(stranger, true);

        vm.expectEmit(address(hook));
        emit StandingPosition.KeeperSet(keeper, false);
        vm.prank(partner);
        hook.setKeeper(keeper, false);
        assertFalse(hook.isKeeper(keeper));
        vm.expectRevert(StandingPosition.NotKeeper.selector);
        vm.prank(keeper);
        (bool gone,) = address(hook).call(move);
        gone;
        vm.expectRevert(StandingPosition.NotKeeperOrHolder.selector);
        vm.prank(keeper);
        hook.takeOut();
    }

    /// @dev The hook's unlock callback answers the PoolManager alone, and its swap callbacks too.
    function test_theCallbacksAnswerThePoolManagerAlone() public {
        _stack();
        StandingPosition hook = _hook();
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        vm.prank(stranger);
        hook.unlockCallback("");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        vm.prank(keeper);
        hook.unlockCallback(hex"01");
    }
}

interface IFloatTarget {
    function setFloatBps(uint16 floatBps) external;
}

/// @notice The standing hook on frxUSD/USDG pegged: a +-0.25% range, a 20% float either side, a 0.05% fee.
contract StandingAnchoredHookPeggedTest is StandingPeggedPair, StandingHookCases {
    function setUp() public override(RehypoRepeatBase, StandingPeggedPair) {
        super.setUp();
    }

    function _peg() internal pure override(RehypoRepeatBase, StandingPeggedPair) returns (uint16) {
        return StandingPeggedPair._peg();
    }

    function _run() internal pure override returns (Run memory) {
        return Run(50, EQUAL, 500, 0, 0);
    }

    function _small(bool zeroForOne) internal pure override returns (uint256) {
        return zeroForOne ? 1e18 : 1e6;
    }

    /// @dev A pegged source's move takes a signed price inside its peg: off it the hook's call reverts as the source's
    /// does, and the position stays.
    function test_offThePegTheMoveRevertsAndThePositionStays() public {
        _stack();
        uint128 liquidity = _liquidity();
        price8 = 0.99e8;
        bytes memory move = _moveData();
        vm.expectRevert(bytes4(keccak256("OffPeg()")));
        vm.prank(keeper);
        (bool ok,) = address(key.hooks).call(move);
        ok;
        assertEq(_liquidity(), liquidity);
    }

    /// @dev The stable entry on a priced pair is refused by the sources, as their own is.
    function test_theStableEntryIsRefusedOnAPricedPair() public {
        _stack();
        uint128 liquidity = _liquidity();
        vm.expectRevert(bytes4(keccak256("PricedSource()")));
        vm.prank(keeper);
        _hook().rebalance(1 << 95, 1 << 97);
        assertEq(_liquidity(), liquidity);
    }
}

/// @notice The standing hook on a stable full-range pair: the keeper's entry with a band (`rebalance`).
contract StandingAnchoredHookStableTest is StandingStablePair {
    function _stack() internal {
        _buildStanding(Run(0, 10_000, 100, 0, 0));
    }

    function test_theStableEntryMovesBothSourcesAndTheNextSwapPlacesTheFullRange() public {
        noFirstPass = true;
        _stack();
        noFirstPass = false;
        assertEq(_liquidity(), 0);
        uint256 float1 = IStandingSource(address(s1)).swapFloat();
        _pass();
        assertEq(_liquidity(), 0, "the move places nothing");
        // The lent side kept a 20% float: the move swept the rest into the vault.
        assertLt(IStandingSource(address(s1)).swapFloat(), float1 / 4, "the move reset the swap float");
        (bool ok, uint256 out) = _trade(-int256(1000e18), _edgePrice(true));
        assertTrue(ok && out > 0);
        (uint128 liquidity, int24 lower, int24 upper) = _hook().position();
        assertGt(liquidity, 0, "the first swap places");
        assertEq(lower, TickMath.minUsableTick(1));
        assertEq(upper, TickMath.maxUsableTick(1));
        (uint256 a0, uint256 a1) = _hook().positionAmounts();
        assertGt(a0, 0);
        assertGt(a1, 0);
        vm.warp(block.timestamp + 5 minutes);
        _pass();
        assertEq(_liquidity(), 0, "and the next move takes it out");
        (ok, out) = _trade(-int256(1000e6), _edgePrice(false));
        assertTrue(ok && out > 0, "the swap after it places again");
        assertGt(_liquidity(), 0);
    }

    function test_thePricedEntryIsRefusedOnAStablePair() public {
        _stack();
        uint128 liquidity = _liquidity();
        vm.expectRevert(bytes4(keccak256("StableSource()")));
        vm.prank(keeper);
        _hook().rebalanceAt(abi.encode(uint256(1e8), block.timestamp));
        assertEq(_liquidity(), liquidity);
    }
}
