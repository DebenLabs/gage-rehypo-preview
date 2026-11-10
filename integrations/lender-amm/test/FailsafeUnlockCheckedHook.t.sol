// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IGageRehypoSource, UnlockingLp} from "./RehypoSourcePlug.t.sol";
import {RehypoSourceFailsafeHookTest, IGageRehypoSourceFactoryFailsafe} from "./RehypoSourcePlugFailsafe.t.sol";
import {RehypoSourceSettings} from "../script/RehypoSource.s.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {KitBands} from "./utils/KitBands.sol";
import {UnlockCheckedHook} from "../src/UnlockCheckedHook.sol";
// Imported so the tests can deploy it by name (`deployCodeTo`).
import {FailsafeUnlockCheckedHook} from "../src/FailsafeUnlockCheckedHook.sol";

/// @notice The deployable failsafe hook (`src/FailsafeUnlockCheckedHook.sol`, the one the testnet pools run) through the
/// whole plug suite and the failsafe tests: a swap the float can fill makes no vault call, a larger one draws, a refused
/// draw leaves the swap to the float, past the band it draws nothing. Where the stock hook lets an LP move inside its
/// own unlock and the source refuses the exit, this hook refuses the move first; and a source without the failsafe,
/// which reverts the ask, leaves a large swap to its float.
contract FailsafeUnlockCheckedHookTest is RehypoSourceFailsafeHookTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        _sources();
        _plug(
            address(FLAGS | (uint160(0x7575) << 144)),
            "FailsafeUnlockCheckedHook.sol:FailsafeUnlockCheckedHook",
            abi.encode(uint256(0), uint256(0), uint24(0))
        );
    }

    /// @dev The parent's LP, one percent of the shares in, outside any unlock.
    function _lpIn() internal returns (UnlockingLp who, uint256 shares) {
        who = _unlockingLp(hook, poolKey);
        shares = hook.totalSupply() / 100;
        who.add(shares);
    }

    function test_anExitInsideItsOwnUnlockStillWaitsWhileTheVaultSettles() public override {
        (UnlockingLp who, uint256 shares) = _lpIn();
        usdgVault.setEarliestMaturity(uint40(block.timestamp));
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.removeInsideUnlock(shares);
    }

    function test_anExitInsideItsOwnUnlockPaysTheLivePriceAfterAWriteOff() public override {
        (UnlockingLp who, uint256 shares) = _lpIn();
        usdgVault.lend(40_000e6);
        usdgVault.writeOff(40_000e6);
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.removeInsideUnlock(shares);
        (, uint256 fairUsdg) = hook.previewRedeem(shares);
        uint256 usdgBefore = usdg.balanceOf(address(who));
        who.remove(shares);
        assertEq(usdg.balanceOf(address(who)) - usdgBefore, fairUsdg, "outside an unlock the exit pays the live price");
    }

    function test_anLpCannotFakeTheHooksDebt() public override {
        (UnlockingLp who, uint256 shares) = _lpIn();
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.removeAfterCreditingTheHook(shares);
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.removeAfterASwap(shares);
    }

    /// @dev A second pool on this hook whose sources have no failsafe (the factory's first `create`), seeded and
    /// rebalanced as the parent's.
    function _noFailsafePool() internal returns (PoolKey memory key, MockGageVault vault2) {
        vault2 = new MockGageVault(IERC20(address(usdg)));
        registry.record(address(vault2));
        vm.startPrank(partner);
        IGageRehypoSource frx2 =
            IGageRehypoSource(factory.create(IERC20(address(frx)), address(0), partner, partner, 10_000, "frx3"));
        IGageRehypoSource usdg2 =
            IGageRehypoSource(factory.create(IERC20(address(usdg)), address(vault2), partner, partner, 2000, "usdg3"));
        vm.stopPrank();
        address at = address(FLAGS | (uint160(0x7878) << 144));
        deployCodeTo(
            "FailsafeUnlockCheckedHook.sol:FailsafeUnlockCheckedHook",
            abi.encode(address(manager), address(frx2), address(usdg2), uint256(0), uint256(0), uint24(0)),
            at
        );
        key = PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        manager.initialize(key, PAR);
        vm.startPrank(partner);
        frx2.bind(key);
        usdg2.bind(key);
        usdg2.setKeeper(keeper, true);
        frx.approve(at, type(uint256).max);
        usdg.approve(at, type(uint256).max);
        FailsafeUnlockCheckedHook(payable(at)).seedLiquidity(SEED_FRX, SEED_USDG);
        vm.stopPrank();
        (uint160 lo, uint160 hi) = KitBands.around(PAR);
        vm.prank(keeper);
        usdg2.rebalance(lo, hi);
    }

    function test_failsafe_aSourceWithoutOneRevertsTheAskAndTheSwapGoesOnFromTheFloat() public {
        (PoolKey memory key, MockGageVault vault2) = _noFailsafePool();
        uint256 calls = vault2.calls();
        uint256 usdgBefore = usdg.balanceOf(trader);
        // 15,000 USDG out of a 20,000 float: more than half, so the hook asks, and the source refuses by reverting.
        vm.prank(trader, trader);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 15_000e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(usdg.balanceOf(trader) - usdgBefore, 15_000e6, "the exact output, from the float alone");
        assertEq(vault2.calls(), calls, "no vault call");
    }

    /// @dev The kit's hooks are built on OpenZeppelin's `ReHypothecationHook`, not on its test mock: none of the mock's
    /// test helpers answers, so nothing but the LP functions and the swap callbacks moves the hook's source shares.
    function test_theKitHooksCarryNoTestHelpers() public {
        uint256 frxShares = IERC20(address(frxSource)).balanceOf(address(hook));
        uint256 usdgShares = IERC20(address(usdgSource)).balanceOf(address(hook));
        bytes[5] memory helpers = [
            abi.encodeWithSignature("burnYieldSourcesBalance(address,uint256)", address(usdg), 1e6),
            abi.encodeWithSignature("getAmountInYieldSource(address)", address(usdg)),
            abi.encodeWithSignature("getMaxWithdrawFromYieldSource(address)", address(usdg)),
            abi.encodeWithSignature("getLiquidityToUse()"),
            abi.encodeWithSignature("test()")
        ];
        for (uint256 i; i < helpers.length; ++i) {
            (bool ok,) = address(hook).call(helpers[i]);
            assertFalse(ok, "a test helper answered");
        }
        assertEq(IERC20(address(frxSource)).balanceOf(address(hook)), frxShares);
        assertEq(IERC20(address(usdgSource)).balanceOf(address(hook)), usdgShares);
    }

    /// @dev A pool binds the hook only if its tokens are the sources' assets, in order: a pool of another pair, or of
    /// the same pair the other way round, cannot take the hook first.
    function test_onlyThePoolOfItsSourcesAssetsBindsTheHook() public {
        address at = address(FLAGS | (uint160(0x7979) << 144));
        deployCodeTo(
            "FailsafeUnlockCheckedHook.sol:FailsafeUnlockCheckedHook",
            abi.encode(address(manager), address(frxSource), address(usdgSource), uint256(0), uint256(0), uint24(0)),
            at
        );
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        (address a, address b) =
            address(other) < address(usdg) ? (address(other), address(usdg)) : (address(usdg), address(other));
        PoolKey memory wrong = PoolKey(Currency.wrap(a), Currency.wrap(b), FEE, TICK_SPACING, IHooks(at));
        vm.expectRevert();
        manager.initialize(wrong, PAR);
        PoolKey memory right =
            PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        manager.initialize(right, PAR);
        assertEq(Currency.unwrap(FailsafeUnlockCheckedHook(payable(at)).getPoolKey().currency0), address(frx));
    }

    /// @dev An ask the source answers with an empty revert (its vault ran out of gas) reverts the swap: the gas a swapper
    /// sends cannot choose the float over the vault. A refusal with a reason leaves the swap to the float.
    function test_anOutOfGasAskRevertsTheSwap() public {
        bytes memory ask = abi.encodeWithSelector(IDrawOnVault.drawOnVault.selector);
        vm.mockCallRevert(address(usdgSource), ask, "");
        vm.expectRevert();
        this.buyUsdg(15_000e6);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(usdgSource), ask, abi.encodeWithSignature("NoFailsafe()"));
        uint256 before = usdg.balanceOf(trader);
        this.buyUsdg(15_000e6);
        assertEq(usdg.balanceOf(trader) - before, 15_000e6, "a refusal with a reason: the float fills it");
    }

    // ------------------------------------------------ the ask sized on what the swap can take

    function swapOut(uint256 amount, uint160 limit) external {
        require(msg.sender == address(this));
        vm.prank(trader, trader);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Property: an exact-output swap stopped a millionth below the price, naming 50,000 USDG (more than twice the
    /// USDG swap float), takes a dust amount and asks nothing: the failsafe's room stays whole and the vault is not
    /// called. When the ask followed the amount named, such a swap took the whole room for a dust fill.
    function test_failsafe_aSwapStoppedAtThePriceDrawsNothing() public {
        uint256 room = IFailsafeRoom(address(usdgSource)).failsafeLeft();
        assertGt(room, 0);
        uint256 calls = usdgVault.calls();
        uint160 p = _price();
        uint256 before = usdg.balanceOf(trader);
        this.swapOut(50_000e6, p - p / 2_000_000);
        assertLt(usdg.balanceOf(trader) - before, 1e6, "a dust fill");
        assertEq(IFailsafeRoom(address(usdgSource)).failsafeLeft(), room, "the room stays whole");
        assertEq(usdgVault.calls(), calls, "no vault call");
    }

    /// @dev Property: whatever an exact-output swap names and wherever its limit, the hook draws only for a swap that
    /// can take more than half of what the USDG side backs, so it never draws more than twice what the swap took; and
    /// what the swap left of the draw is back in the vault, the room whole again, after the next keeper move.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_failsafe_aDrawIsWhatTheSwapTakesAndTheRestGoesBack(uint256 amount, uint256 reach) public {
        amount = bound(amount, 1e6, 200_000e6);
        // How far below the price the limit sits, in millionths of the sqrt price: up to 70%, past the half line.
        reach = bound(reach, 1, 700_000);
        uint160 p = _price();
        uint160 limit = uint160(p - Math.mulDiv(p, reach, 1e6));
        uint256 cash = usdgVault.cash();
        uint256 before = usdg.balanceOf(trader);
        this.swapOut(amount, limit);
        uint256 took = usdg.balanceOf(trader) - before;
        uint256 drawn = cash - usdgVault.cash();
        assertLe(drawn, 2 * took + 2, "never more drawn than twice what the swap took");
        if (2 * amount <= SEED_USDG / 5 || 2 * reach < 1e6) {
            assertEq(drawn, 0, "a swap that cannot take half asks nothing");
        }
        // The keeper's next move, on a band around wherever the swap left the price.
        vm.warp(block.timestamp + 5 minutes);
        (uint160 lo, uint160 hi) = KitBands.around(_price());
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        uint256 target = usdgSource.totalAssets() * 2000 / 10_000;
        assertLe(usdgSource.float(), target + 1e6, "what the swap left of the draw is back in the vault");
        uint256 backing = usdgSource.totalAssets();
        assertApproxEqAbs(IFailsafeRoom(address(usdgSource)).failsafeLeft(), backing / 10, 2, "the room is whole");
    }

    // ------------------------------------------------ the draw only where it pays, exact input too

    /// @dev A second pool whose USDG source has the failsafe, on a failsafe hook drawing only when the swap's fee covers
    /// `minDrawFee1` (USDG raw units) and `forgonePips` of the ask; seeded and rebalanced as the parent's.
    function _economicPool(uint256 minDrawFee1, uint24 forgonePips, uint160 salt)
        internal
        returns (PoolKey memory key, IGageRehypoSource usdg2, MockGageVault vault2)
    {
        vault2 = new MockGageVault(IERC20(address(usdg)));
        registry.record(address(vault2));
        RehypoSourceSettings memory stable;
        IGageRehypoSourceFactoryFailsafe f = IGageRehypoSourceFactoryFailsafe(address(factory));
        vm.startPrank(partner);
        IGageRehypoSource frx2 = IGageRehypoSource(
            f.create(IERC20(address(frx)), address(0), partner, partner, 10_000, stable, 0, bytes32(uint256(salt)))
        );
        usdg2 = IGageRehypoSource(
            f.create(
                IERC20(address(usdg)), address(vault2), partner, partner, 2000, stable, 1000, bytes32(uint256(salt))
            )
        );
        vm.stopPrank();
        address at = address(FLAGS | (salt << 144));
        deployCodeTo(
            "FailsafeUnlockCheckedHook.sol:FailsafeUnlockCheckedHook",
            abi.encode(address(manager), address(frx2), address(usdg2), uint256(0), minDrawFee1, forgonePips),
            at
        );
        key = PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        manager.initialize(key, PAR);
        vm.startPrank(partner);
        frx2.bind(key);
        usdg2.bind(key);
        usdg2.setKeeper(keeper, true);
        frx.approve(at, type(uint256).max);
        usdg.approve(at, type(uint256).max);
        FailsafeUnlockCheckedHook(payable(at)).seedLiquidity(SEED_FRX, SEED_USDG);
        vm.stopPrank();
        (uint160 lo, uint160 hi) = KitBands.around(PAR);
        vm.prank(keeper);
        usdg2.rebalance(lo, hi);
    }

    /// @dev Exactly `amount` USDG out of `key`'s pool for frxUSD; returns what the vault paid out (the draw).
    function _drawFor(PoolKey memory key, MockGageVault vault2, uint256 amount) internal returns (uint256 drawn) {
        uint256 cash = vault2.cash();
        vm.prank(trader, trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        drawn = cash - vault2.cash();
    }

    /// @dev 15,000 USDG out of a 20,000 swap float at a 1 bp fee: the ask is 2 x 15,000 - 20,000 = 10,000 USDG, and the
    /// fee on what the swap needs beyond half the side, 5,000 USDG, is 0.5 USDG. A draw cost of exactly that draws; one
    /// raw unit more, and the swap fills on the float alone.
    function test_failsafe_aDrawMustPayItsCost() public {
        uint256 snapshot = vm.snapshotState();
        (PoolKey memory key, IGageRehypoSource usdg2, MockGageVault vault2) = _economicPool(0.5e6, 0, 0x8181);
        assertEq(Math.min(usdg2.float(), usdg2.swapFloat()), 20_000e6);
        assertGt(_drawFor(key, vault2, 15_000e6), 0, "a draw whose fee covers its cost");
        vm.revertToStateAndDelete(snapshot);
        (key, usdg2, vault2) = _economicPool(0.5e6 + 1, 0, 0x8282);
        uint256 before = usdg.balanceOf(trader);
        assertEq(_drawFor(key, vault2, 15_000e6), 0, "a draw that would not pay is not asked");
        assertEq(usdg.balanceOf(trader) - before, 15_000e6, "the float alone fills it");
    }

    /// @dev The lending return the draw gives up counts on the whole ask: at a 1 bp fee a draw pays only while that
    /// return is at most half the fee, 50 pips.
    function test_failsafe_aDrawMustPayTheLendingItGivesUp() public {
        uint256 snapshot = vm.snapshotState();
        (PoolKey memory key,, MockGageVault vault2) = _economicPool(0, 50, 0x8383);
        assertGt(_drawFor(key, vault2, 15_000e6), 0, "the fee on half the ask covers 50 pips of it");
        vm.revertToStateAndDelete(snapshot);
        (key,, vault2) = _economicPool(0, 51, 0x8484);
        assertEq(_drawFor(key, vault2, 15_000e6), 0, "51 pips of the ask is more than the fee earns");
    }

    /// @dev The forgone return is bounded at 1% of a draw.
    function test_failsafe_theForgoneReturnIsBounded() public {
        address at = address(FLAGS | (uint160(0x8585) << 144));
        vm.expectRevert(abi.encodeWithSelector(FailsafeUnlockCheckedHook.InvalidForgonePips.selector, uint24(10_001)));
        deployCodeTo(
            "FailsafeUnlockCheckedHook.sol:FailsafeUnlockCheckedHook",
            abi.encode(
                address(manager), address(frxSource), address(usdgSource), uint256(0), uint256(0), uint24(10_001)
            ),
            at
        );
    }

    /// @dev An exact-input swap asks too: 15,000 frxUSD in at a dollar would take about 15,000 USDG out of a 20,000 swap
    /// float, more than half, so the hook asks and the vault's cash deepens it; 5,000 frxUSD in asks nothing.
    function test_failsafe_anExactInputSwapAsksToo() public {
        uint256 snapshot = vm.snapshotState();
        uint256 calls = usdgVault.calls();
        _sellFrx(5000e18);
        assertEq(usdgVault.calls(), calls, "a swap the float fills makes no vault call");
        vm.revertToStateAndDelete(snapshot);
        uint256 cash = usdgVault.cash();
        _sellFrx(15_000e18);
        assertGt(cash - usdgVault.cash(), 0, "the larger exact-input swap drew");
    }

    function _sellFrx(uint256 amount) internal {
        vm.prank(trader, trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function buyUsdg(uint256 amount) external {
        require(msg.sender == address(this));
        vm.prank(trader, trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

interface IDrawOnVault {
    function drawOnVault(uint256 assets) external returns (uint256 drawn);
}

interface IFailsafeRoom {
    function failsafeLeft() external view returns (uint256);
}
