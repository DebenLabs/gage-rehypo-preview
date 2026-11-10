// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {
    ReHypothecationERC4626Mock,
    ERC4626YieldSourceMock
} from "@openzeppelin/uniswap-hooks/src/mocks/general/ReHypothecationERC4626Mock.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {KitBands} from "./utils/KitBands.sol";
import {UnlockCheckedHook} from "../src/UnlockCheckedHook.sol";

/// @notice What a partner calls on gage's rehypo source factory and its sources (`src/rehypo/`).
interface IGageRehypoSourceFactory {
    function create(IERC20 asset, address vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (address source);
}

interface IGageRehypoSource is IERC4626 {
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function setFloatBps(uint16 floatBps) external;
    function rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) external;
    function claimPockets(uint256[] calldata pocketIds) external;
    function RELEASE() external view returns (uint32);
    function PAST_BAND_BPS() external view returns (uint16);
    function floatBps() external view returns (uint16);
    function swapFloat() external view returns (uint256);
    function float() external view returns (uint256);
}

/// @notice Plug and play: OpenZeppelin's own ERC-4626 rehypothecation hook (uniswap-hooks' `ReHypothecationERC4626Mock`,
/// unmodified) on gage's rehypo sources, built from `contracts/` (`forge build` there first). A stable pair as a partner
/// would run it on day one: frxUSD float-only, USDG lent through a gage vault. The pool manager starts empty: the
/// sources keep their floats in it as claims, so the hook's after-swap take finds its reserve without anyone topping it
/// up, and swaps run with the gage vault offline, so a swap never touches it.
contract RehypoSourcePlugTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    uint24 internal constant FEE = 100;
    int24 internal constant TICK_SPACING = 1;
    /// @dev One frxUSD (18 decimals) for one USDG (6 decimals): a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;

    MockERC20 internal frx;
    MockERC20 internal usdg;
    MockGageVault internal usdgVault;
    FactoryRegistryStandIn internal registry;
    IGageRehypoSourceFactory internal factory;
    IGageRehypoSource internal frxSource;
    IGageRehypoSource internal usdgSource;
    ReHypothecationERC4626Mock internal hook;
    PoolKey internal poolKey;

    address internal partner = makeAddr("partner safe");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        frx = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), address(frx));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        usdgVault = new MockGageVault(IERC20(address(usdg)));

        // The partner's Safe batch: two sources, the hook naming them, the pool, the bindings, the seed.
        registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        factory = IGageRehypoSourceFactory(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(manager), address(registry), address(0)))
        );
        vm.startPrank(partner);
        frxSource = IGageRehypoSource(factory.create(IERC20(address(frx)), address(0), partner, partner, 10_000, "frx"));
        usdgSource = IGageRehypoSource(
            factory.create(IERC20(address(usdg)), address(usdgVault), partner, partner, 2000, "usdg")
        );
        vm.stopPrank();

        address at = address(FLAGS | (uint160(0x5555) << 144));
        deployCodeTo(
            "ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(frxSource), address(usdgSource)),
            at
        );
        hook = ReHypothecationERC4626Mock(payable(at));
        poolKey = PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        manager.initialize(poolKey, PAR);

        vm.startPrank(partner);
        frxSource.bind(poolKey);
        usdgSource.bind(poolKey);
        usdgSource.setKeeper(keeper, true);
        vm.stopPrank();

        address[3] memory holders = [partner, trader, lp];
        for (uint256 i; i < holders.length; ++i) {
            frx.mint(holders[i], 1_000_000e18);
            usdg.mint(holders[i], 1_000_000e6);
            vm.startPrank(holders[i]);
            frx.approve(at, type(uint256).max);
            usdg.approve(at, type(uint256).max);
            frx.approve(address(swapRouter), type(uint256).max);
            usdg.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(partner);
        hook.seedLiquidity(SEED_FRX, SEED_USDG);
        (uint160 lo, uint160 hi) = KitBands.around(PAR);
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
    }

    function _swapAs(address who, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(who, who);
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function _claims(IGageRehypoSource s) internal view returns (uint256) {
        return manager.balanceOf(address(s), uint256(uint160(s.asset())));
    }

    function test_theStockHookSeedsIntoTheSourcesAndTheUsdgSideIsLent() public view {
        assertEq(_claims(frxSource), SEED_FRX, "frxUSD stays whole in the float");
        assertEq(_claims(usdgSource), SEED_USDG / 5, "20% of the USDG stays in the float");
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5, "80% is in the gage vault");
        assertEq(frx.balanceOf(address(manager)), SEED_FRX, "the manager holds exactly the floats, nothing else");
        assertEq(usdg.balanceOf(address(manager)), SEED_USDG / 5);
    }

    function test_swapsRunOnTheFloatsWithTheVaultOffline() public {
        uint256 callsBefore = usdgVault.calls();
        usdgVault.setOffline(true);
        uint256 usdgBefore = usdg.balanceOf(trader);
        _swapAs(trader, true, -1000e18);
        uint256 out = usdg.balanceOf(trader) - usdgBefore;
        assertGt(out, 900e6, "a 1,000 frxUSD sale against a 20,000 USDG float");
        // The hook rounds its just-in-time liquidity against itself: a few raw units of dust per swap.
        assertApproxEqAbs(_claims(usdgSource), SEED_USDG / 5 - out, 10, "the USDG float paid the trader");
        assertApproxEqAbs(_claims(frxSource), SEED_FRX + 1000e18, 1e13, "the frxUSD float took the sale");

        uint256 frxBefore = frx.balanceOf(trader);
        _swapAs(trader, false, -500e6);
        assertGt(frx.balanceOf(trader) - frxBefore, 490e18);
        assertEq(usdgVault.calls(), callsBefore, "no swap called the vault");
    }

    function test_aBigSaleNeverTakesMoreThanTheFloat() public {
        usdgVault.setOffline(true);
        uint256 usdgBefore = usdg.balanceOf(trader);
        _swapAs(trader, true, -15_000e18);
        assertLt(usdg.balanceOf(trader) - usdgBefore, SEED_USDG / 5, "never more than the USDG float");
    }

    function test_lpsEnterAndLeaveThroughTheVaultOutsideSwaps() public {
        uint256 shares = hook.balanceOf(partner) / 2;
        uint256 usdgBefore = usdg.balanceOf(partner);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        uint256 usdgOut = usdg.balanceOf(partner) - usdgBefore;
        assertApproxEqRel(usdgOut, SEED_USDG / 2, 1e15, "half the USDG backing, through the vault");
        assertApproxEqAbs(_claims(usdgSource), SEED_USDG / 10, 1e3, "the float keeps the swap float's share");

        vm.prank(lp);
        hook.addReHypothecatedLiquidity(shares / 2, type(uint256).max, type(uint256).max);
        assertGt(usdgSource.float(), 0);
        assertLt(usdgSource.swapFloat(), usdgSource.float(), "an entry deepens swaps by its share only");
    }

    function test_lpsWaitWhileTheVaultSettlesButSwapsGoOn() public {
        usdgVault.setEarliestMaturity(uint40(block.timestamp));
        uint256 shares = hook.balanceOf(partner) / 10;
        vm.prank(partner);
        vm.expectRevert();
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        _swapAs(trader, true, -1000e18);
    }

    // ------------------------------------------------ an LP exit and the swap float
    // The stock hook sizes a swap's liquidity by the smaller side's `maxWithdraw`, which inside a swap is the swap
    // float: a USDG swap float at zero refuses every swap both ways, and only the keeper's rebalance opens it again.
    // Inside the keeper's price band it opens swaps in full; past the band, to at most
    // 1% of the float target (`PAST_BAND_BPS`), or no further than they were if that is more. An LP exit keeps the swap
    // float its share of what stays while the vault's free cash can pay the rest: no such exit closes the pool, in the
    // band or past it. When the vault cannot pay its part, the float does, so LPs keep their exits.

    bytes4 internal constant VAULT_SETTLING = bytes4(keccak256("VaultSettling()"));
    bytes4 internal constant INVALID_BAND = bytes4(keccak256("InvalidBand()"));

    /// @dev The keeper's band for this pool: 0.5% either side of one frxUSD for one USDG (`RehypoSource.s.sol`).
    function _band() internal pure returns (uint160 lo, uint160 hi) {
        return (_sqrtPriceAt(9950), _sqrtPriceAt(10_050));
    }

    /// @dev The sqrt price of `bps / 10,000` USDG per frxUSD, in raw units, as the script computes it.
    function _sqrtPriceAt(uint256 bps) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(bps * 1e6, 1 << 192, 10_000 * 1e18)));
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
    }

    /// @dev A swap as `who` that sells what it takes to bring the price to `limit`.
    function _swapTo(address who, bool zeroForOne, uint160 limit) internal {
        vm.prank(who, who);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(500_000e18) : -int256(500_000e6),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev The float target now, as the keeper's next rebalance computes it.
    function _target() internal view returns (uint256) {
        return Math.mulDiv(usdgSource.totalAssets(), usdgSource.floatBps(), 10_000);
    }

    /// @dev The swap float a rebalance just past the band opens a stopped pool to: 1% of `target`, the edge depth.
    function _pastBandDepth(uint256 target) internal view returns (uint256) {
        return Math.mulDiv(target, usdgSource.PAST_BAND_BPS(), 10_000);
    }

    /// @dev The source's past-band cap, written out on its own: the edge depth times the square of the price's ratio to
    /// the edge it is past, (s)^4 in sqrt prices, rounded down at each step.
    function _capAt(uint256 target, uint160 price, uint160 lo, uint160 hi) internal view returns (uint256 cap) {
        cap = _pastBandDepth(target);
        (uint256 num, uint256 den) = price < lo ? (uint256(price), uint256(lo)) : (uint256(hi), uint256(price));
        for (uint256 i; i < 4; ++i) {
            cap = Math.mulDiv(cap, num, den);
        }
    }

    /// @dev F1: a fifth of the pool leaves, 20,000 USDG, as much as the whole USDG float.
    function test_anExitAsLargeAsTheFloatLeavesSwapsOpen() public {
        uint256 cashBefore = usdgVault.cash();
        uint256 fifth = hook.totalSupply() / 5;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(fifth, 0, 0);
        assertApproxEqAbs(usdgSource.swapFloat(), 16_000e6, 1e3, "the swap float keeps its share of what stays");
        assertApproxEqAbs(cashBefore - usdgVault.cash(), 16_000e6, 1e3, "the vault's free cash paid the rest");
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);
    }

    /// @dev F2: a trader pushes the price just past the keeper's band. The keeper's rebalance goes through and deepens
    /// nothing: it leaves the swap float where it was or at 1% of the target, whichever is more. Then a quarter of the
    /// pool leaves. Swaps stay open, so anyone can trade the price back, and the keeper opens them in full again.
    function test_aPricePushedPastTheBandAndAnExitCannotFreezeThePool() public {
        (uint160 lo, uint160 hi) = _band();
        uint160 past = hi + hi / 10_000;
        _swapTo(trader, false, past);
        assertEq(_price(), past, "the price sits just past the band");
        uint256 before = usdgSource.swapFloat();
        uint256 target = _target();
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertLe(usdgSource.swapFloat(), Math.max(before, _pastBandDepth(target)), "past the band, no deeper");
        assertLe(usdgSource.swapFloat(), target, "nor above the target");

        uint256 quarter = hook.totalSupply() / 4;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(quarter, 0, 0);
        assertGt(usdgSource.swapFloat(), 0, "the exit left swaps open");

        _swapTo(trader, true, PAR);
        assertEq(_price(), PAR, "traded back into the band");
        target = _target();
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertEq(usdgSource.swapFloat(), target, "inside the band, swaps open in full");
    }

    /// @dev F4: after an exit the vault refuses every share change (its reward source cannot deliver), then waits for a
    /// loan's settle. The keeper cannot move through either, and need not: the exit left the swap float its share.
    function test_whileTheVaultRefusesAfterAnExitSwapsGoOn() public {
        uint256 quarter = hook.totalSupply() / 4;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(quarter, 0, 0);
        usdgVault.setRewardsPending(true);
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);

        usdgVault.setRewardsPending(false);
        usdgVault.setEarliestMaturity(uint40(block.timestamp));
        (uint160 lo, uint160 hi) = KitBands.around(_price());
        vm.prank(keeper);
        vm.expectRevert(VAULT_SETTLING);
        usdgSource.rebalance(lo, hi);
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);
    }

    /// @dev Past the band the keeper resets the swap float to no more than where it was or 1% of the target, and no LP
    /// move raises its share of the backing: an exit keeps only its share, an entry adds only its share, in either
    /// order and at any size, a flash entrant's too.
    function test_atAPushedPriceNoLpMoveDeepensSwaps() public {
        (uint160 lo, uint160 hi) = _band();
        _swapTo(trader, false, hi + hi / 10_000);
        uint256 depth = usdgSource.swapFloat();
        uint256 backing = usdgSource.totalAssets();

        uint256 half = hook.balanceOf(partner) / 2;
        vm.startPrank(partner);
        hook.removeReHypothecatedLiquidity(half, 0, 0);
        assertLe(usdgSource.swapFloat(), Math.mulDiv(depth, usdgSource.totalAssets(), backing), "an exit");
        hook.addReHypothecatedLiquidity(half, type(uint256).max, type(uint256).max);
        assertLe(usdgSource.swapFloat(), Math.mulDiv(depth, usdgSource.totalAssets(), backing), "then an entry");
        vm.stopPrank();

        address flash = makeAddr("flash entrant");
        frx.mint(flash, 10_000_000e18);
        usdg.mint(flash, 10_000_000e6);
        uint256 shares = hook.totalSupply() * 99;
        vm.startPrank(flash);
        frx.approve(address(hook), type(uint256).max);
        usdg.approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        assertLe(usdgSource.swapFloat(), Math.mulDiv(depth, usdgSource.totalAssets(), backing), "a flash entry");
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();
        assertLe(usdgSource.swapFloat(), Math.mulDiv(depth, usdgSource.totalAssets(), backing), "and its exit");

        uint256 before = usdgSource.swapFloat();
        uint256 target = _target();
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertLe(usdgSource.swapFloat(), Math.max(before, _pastBandDepth(target)), "nor the keeper's rebalance");
    }

    // A pusher can still stop swaps past the band, and cheaply, on a thin float: another depositor of the vault takes
    // its free cash, so the float alone pays LP exits; LP exits take all but a sliver of the float; the push past the
    // band on the sliver; the rest of the float leaves; the cash goes back. The keeper's own rebalance then opens 1% of
    // the target at the pushed price. On a sliver about that deep, the push costs more than the trade back pays; on a
    // thinner one the pusher can gain, but less than the reopened depth times the price gap. The keeper's next
    // rebalance, inside the band, opens swaps in full. Gains and costs are the pusher's, valued at one for one in USDG.

    /// @dev The vault's other depositor, whose free cash the pusher borrows for the round.
    address internal vaultDepositor = makeAddr("vault depositor");

    /// @dev The value `who` holds of the two tokens at one for one, in raw USDG.
    function _atPar(address who) internal view returns (int256) {
        return int256(frx.balanceOf(who) / 1e12 + usdg.balanceOf(who));
    }

    /// @dev The most of the partner's hook shares whose exit the USDG source can pay now.
    function _sharesTheSourceCanPay() internal view returns (uint256 shares) {
        uint256 cap = usdgSource.maxWithdraw(address(hook));
        uint256 most = hook.balanceOf(partner);
        while (shares < most) {
            uint256 mid = (shares + most + 1) / 2;
            (, uint256 out) = hook.previewRedeem(mid);
            if (out <= cap) shares = mid;
            else most = mid - 1;
        }
    }

    function _exit(uint256 shares) internal {
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
    }

    /// @dev The pusher's moves up to stopped swaps, LP exits leaving `kept` hundred-thousandths of the float for the push
    /// to `pushed`, above or below one for one. Returns the push's cost to the pusher.
    function _stopSwapsPastTheBand(uint160 pushed, uint256 kept) internal returns (int256 push) {
        usdg.mint(vaultDepositor, 20_000e6);
        vm.startPrank(vaultDepositor);
        usdg.approve(address(usdgVault), type(uint256).max);
        usdgVault.deposit(20_000e6, vaultDepositor);
        vm.stopPrank();
        usdgVault.lend(80_000e6); // the vault's free cash is now the other depositor's 20,000

        vm.prank(vaultDepositor);
        usdgVault.withdraw(20_000e6, vaultDepositor, vaultDepositor);
        _exit(_sharesTheSourceCanPay() * (100_000 - kept) / 100_000);
        int256 start = _atPar(trader);
        _swapTo(trader, pushed < PAR, pushed);
        push = _atPar(trader) - start;
        assertEq(_price(), pushed, "pushed past the band");
        _exit(_sharesTheSourceCanPay());
        vm.prank(vaultDepositor);
        usdgVault.deposit(20_000e6, vaultDepositor);
        assertEq(usdgSource.swapFloat(), 0, "the float is gone, and swaps with it");
        _assertSwapsStopped();
    }

    /// @dev With no USDG swap float, OpenZeppelin's hook finds no usable liquidity: every swap reverts, both ways.
    function _assertSwapsStopped() internal {
        bytes memory stopped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(stopped);
        _swapAs(trader, true, -1e18);
        vm.expectRevert(stopped);
        _swapAs(trader, false, -1e6);
    }

    /// @dev The pusher trades the price back to one for one on the depth there is. Returns its gain.
    function _tradeBack() internal returns (int256 back) {
        int256 start = _atPar(trader);
        _swapTo(trader, _price() > PAR, PAR);
        back = _atPar(trader) - start;
        assertEq(_price(), PAR, "traded back to one for one");
    }

    /// @dev The round against the keeper's own band: swaps stopped at `pushed`, the keeper's rebalance past the band,
    /// the trade back, the keeper's next rebalance inside the band, then swaps both ways. Returns the pusher's net.
    function _boundedRound(uint160 pushed, uint256 kept) internal returns (int256 net, uint256 reopened) {
        int256 push = _stopSwapsPastTheBand(pushed, kept);
        (uint160 lo, uint160 hi) = _band();
        uint256 target = _target();
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        reopened = usdgSource.swapFloat();
        assertEq(usdgSource.float(), target, "the vault still refilled the float");
        assertEq(reopened, _capAt(target, pushed, lo, hi), "swaps open to the scaled cap");

        int256 back = _tradeBack();
        target = _target();
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertEq(usdgSource.swapFloat(), target, "inside the band, swaps open in full");
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);

        net = push + back;
        emit log_named_decimal_int("push, the pusher's change (negative: its cost)", push, 6);
        emit log_named_decimal_uint("depth reopened past the band", reopened, 6);
        emit log_named_decimal_int("trade back, the pusher's change", back, 6);
        emit log_named_decimal_int("pusher's net over the round", net, 6);
        emit log_named_decimal_uint("depth after the rebalance inside the band", target, 6);
    }

    /// @dev Just past the band, 0.52% above one for one, with about 200 USDG of float left for the push.
    function test_aThinFloatPushJustPastTheBandDoesNotPay() public {
        (, uint160 hi) = _band();
        (int256 net,) = _boundedRound(hi + hi / 10_000, 1000);
        assertLt(net, 0, "the pusher loses over the round");
    }

    /// @dev Five percent above one for one, on the same thin float.
    function test_aThinFloatPushFivePercentOffDoesNotPay() public {
        (int256 net,) = _boundedRound(_sqrtPriceAt(10_500), 1000);
        assertLt(net, 0, "the pusher loses over the round");
    }

    /// @dev Twenty percent above one for one, on the same thin float.
    function test_aThinFloatPushTwentyPercentOffDoesNotPay() public {
        (int256 net,) = _boundedRound(_sqrtPriceAt(12_000), 1000);
        assertLt(net, 0, "the pusher loses over the round");
    }

    /// @dev The worst case measured: about 20 USDG of float left for a push 20% off. The trade back can pay more than
    /// that push cost, but it sells into at most the reopened depth at a price at most 20% off, so the pusher gains
    /// less than the reopened depth times the gap.
    function test_onTheThinnestFloatThePushersGainStaysBelowTheReopenedDepthTimesTheGap() public {
        (int256 net, uint256 reopened) = _boundedRound(_sqrtPriceAt(12_000), 100);
        assertLt(net, int256(reopened * 2000 / 10_000), "less than the reopened depth times the gap");
    }

    // The below-band leak: OpenZeppelin's hook builds liquidity from the smaller side's swap float as
    // about `amount / sqrtP` on the side the push favours, so a fixed 1% of the target backed ever more depth the
    // further the price was pushed below the band, and the trade back took the frxUSD side's float, which nothing
    // capped. The scaled cap holds one round to about a sixteenth of the edge depth on either side. Each case runs on a
    // float of about 200, 20 and 1 USDG left for the push.

    /// @dev Rounds at `pushed` on the three floats: the pusher's net stays under a fifteenth of the edge depth.
    function _assertRoundsBounded(uint160 pushed) internal {
        uint256 edge = _pastBandDepth(_target());
        uint256[3] memory floats = [uint256(1000), 100, 5];
        for (uint256 i; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            (int256 net,) = _boundedRound(pushed, floats[i]);
            assertLt(net, int256(edge / 15), "under a fifteenth of the edge depth");
            vm.revertToStateAndDelete(snapshot);
        }
    }

    function test_aRoundJustBelowTheBandIsBounded() public {
        (uint160 lo,) = _band();
        _assertRoundsBounded(lo - lo / 10_000);
    }

    function test_aRoundFivePercentBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(9500));
    }

    function test_aRoundTwentyPercentBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(8000));
    }

    function test_aRoundHalfBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(5000));
    }

    function test_aRoundThreeQuartersBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(2500));
    }

    function test_aRoundNinetyNinePercentBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(100));
    }

    function test_aRoundNinetyNinePointEightPercentBelowIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(20));
    }

    function test_aRoundFivePercentAboveIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(10_500));
    }

    function test_aRoundTwiceTheUpperEdgeIsBounded() public {
        _assertRoundsBounded(_sqrtPriceAt(20_000));
    }

    /// @dev The keeper reopens on every pass, so a pusher may trade back in steps
    /// between passes, each reopening to the cap at a price nearer the edge. Over the stretch it gains under a quarter of
    /// the edge depth, the bound the docs state.
    function test_aTradeBackAcrossTheKeepersPassesPaysUnderAQuarterOfTheEdgeDepth() public {
        uint256 edge = _pastBandDepth(_target());
        int256 net = _stopSwapsPastTheBand(_sqrtPriceAt(100), 100);
        (uint160 lo, uint160 hi) = _band();
        for (uint256 pass; pass < 20 && _price() < lo; ++pass) {
            vm.prank(keeper);
            usdgSource.rebalance(lo, hi);
            int256 start = _atPar(trader);
            uint160 step = uint160(Math.min(uint256(_price()) * 2, PAR));
            _swapTo(trader, false, step);
            net += _atPar(trader) - start;
        }
        assertGe(_price(), lo, "traded back into the band");
        emit log_named_decimal_int("pusher's net over the stretch", net, 6);
        assertLt(net, int256(edge / 4), "under a quarter of the edge depth");
    }

    /// @dev What the keeper never sends: the same push 5% off, then a rebalance with its band widened to the pushed
    /// price, the remedy an earlier guide gave. It would open the whole target at the pushed price, and trading the
    /// price back on that depth would pay the pusher more than the push cost; the source refuses the band.
    function test_aBandWidenedToThePushedPriceIsRefused() public {
        uint160 pushed = _sqrtPriceAt(10_500);
        _stopSwapsPastTheBand(pushed, 1000);
        (uint160 lo,) = _band();
        uint256 depth = usdgSource.swapFloat();
        // Widened from the band's lower edge to a price 5% up, the whole target would open at the pushed price and pay
        // the pusher; a stable band is at most `MAX_STABLE_BAND_TICKS` wide, so the source refuses it.
        vm.prank(keeper);
        vm.expectRevert(INVALID_BAND);
        usdgSource.rebalance(lo, pushed);
        assertEq(usdgSource.swapFloat(), depth, "swaps stay where the cap past the band left them");
    }

    /// @dev The review of that fix: when the vault cannot pay its part, the float does, so LPs can always take the float
    /// and the vault's free cash. The guide's emergency lever with three quarters of the vault on loan: float to
    /// 100%, the keeper pulls the free 20,000 back, then a repaid 20,000 on its next pass. An LP removing 1% of the pool
    /// goes through each time.
    function test_theEmergencyLeverKeepsLpExitsOpen() public {
        usdgVault.lend(60_000e6);
        vm.prank(partner);
        usdgSource.setFloatBps(10_000);
        (uint160 lo, uint160 hi) = KitBands.around(_price());
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertEq(usdgSource.maxWithdraw(address(hook)), 40_000e6, "the float and the vault's free cash");
        uint256 onePercent = hook.balanceOf(partner) / 100;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(onePercent, 0, 0);

        usdg.mint(address(usdgVault), 20_000e6);
        usdgVault.repay(20_000e6, 0);
        (lo, hi) = KitBands.around(_price());
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertApproxEqAbs(usdgSource.float(), 59_000e6, 1e3, "the repaid 20,000 joined the float");
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(onePercent, 0, 0);
        _swapAs(trader, true, -1000e18);
    }

    /// @dev In the vault's purchase second its maxima are zero: the float pays an LP's exit, and swaps go on.
    function test_aFillsSecondLeavesLpExitsToTheFloat() public {
        usdgVault.setPurchaseSecond(uint40(block.timestamp));
        uint256 onePercent = hook.balanceOf(partner) / 100;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(onePercent, 0, 0);
        assertApproxEqAbs(usdgSource.float(), SEED_USDG / 5 - SEED_USDG / 100, 1e3, "the float paid it");
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);
    }

    /// @dev While the vault refuses every share change (`RewardsPending`, which its maximum does not model), the float
    /// pays an LP's exit the vault would have paid part of, and swaps go on.
    function test_whileTheVaultRefusesTheFloatPaysLpExits() public {
        usdgVault.setRewardsPending(true);
        uint256 onePercent = hook.balanceOf(partner) / 100;
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(onePercent, 0, 0);
        assertApproxEqAbs(usdgSource.float(), SEED_USDG / 5 - SEED_USDG / 100, 1e3, "the float paid it");
        _swapAs(trader, true, -1000e18);
        _swapAs(trader, false, -1000e6);
    }

    /// @dev Interest the vault has accrued is priced, not yet cash. An exit now takes most of its USDG from the vault
    /// at its live price: the leaver gets what its shares are worth and the LP who stays keeps what its shares are
    /// worth. A flash entrant's round trip after it takes nothing.
    function test_anExitThroughTheVaultSkimsNothingOfItsAccruedValue() public {
        usdgVault.accrue(4000e6);
        uint256 half = hook.balanceOf(partner) / 2;
        (, uint256 fair) = hook.previewRedeem(half);
        (, uint256 stays) = hook.previewRedeem(hook.balanceOf(partner) - half);
        uint256 backing = usdgSource.totalAssets();
        uint256 lent = backing - usdgSource.float();
        uint256 cashBefore = usdgVault.cash();
        uint256 partnerBefore = usdg.balanceOf(partner);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(half, 0, 0);
        assertEq(usdg.balanceOf(partner) - partnerBefore, fair, "the leaver gets its shares' worth");
        assertApproxEqAbs(
            cashBefore - usdgVault.cash(), Math.mulDiv(fair, lent, backing), 1e3, "the vault's part of it"
        );
        (, uint256 kept) = hook.previewRedeem(hook.balanceOf(partner));
        assertApproxEqAbs(kept, stays, 10, "the LP who stays keeps its shares' worth");

        address flash = makeAddr("flash entrant");
        frx.mint(flash, 10_000_000e18);
        usdg.mint(flash, 10_000_000e6);
        uint256 frxBefore = frx.balanceOf(flash);
        uint256 usdgBefore = usdg.balanceOf(flash);
        uint256 shares = hook.totalSupply() * 99;
        vm.startPrank(flash);
        frx.approve(address(hook), type(uint256).max);
        usdg.approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();
        assertLe(frx.balanceOf(flash), frxBefore, "no frxUSD to the flash entrant");
        assertLe(usdg.balanceOf(flash), usdgBefore, "no USDG either");
        (, kept) = hook.previewRedeem(hook.balanceOf(partner));
        assertApproxEqAbs(kept, stays, 10, "and the LP who stays still keeps its shares' worth");
    }

    // ------------------------------------------------ a pocket claimed around an entry
    // A loan repaid early leaves the part of its fixed cost the vault's share price had not counted in a side pocket,
    // owed to the shares that carried the loan: here the source's, earned by the LPs who were in while it ran. Anyone may
    // claim it for the source, so a flash borrower could enter just before the claim and leave just after: the source
    // holds the proceeds out of its float and releases them over a day (`RELEASE`).

    function test_aFlashEntryAroundAPocketClaimTakesNoneOfThePocket() public {
        uint256 pocket = 1000e6;
        usdg.mint(address(usdgVault), pocket);
        uint256[] memory ids = new uint256[](1);
        ids[0] = usdgVault.openPocket(address(usdg), address(usdgSource), pocket);
        (, uint256 lpsBefore) = hook.previewRedeem(hook.balanceOf(partner));

        // One block with no time passing, as inside a flash loan: borrow 99 times the pool, enter, claim, leave, repay.
        address borrower = makeAddr("flash borrower");
        frx.mint(borrower, 10_000_000e18);
        usdg.mint(borrower, 10_000_000e6);
        uint256 frxBefore = frx.balanceOf(borrower);
        uint256 usdgBefore = usdg.balanceOf(borrower);
        uint256 shares = hook.totalSupply() * 99;
        vm.startPrank(borrower);
        frx.approve(address(hook), type(uint256).max);
        usdg.approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        usdgSource.claimPockets(ids);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();

        assertLe(frx.balanceOf(borrower), frxBefore, "no frxUSD gained");
        assertLe(usdg.balanceOf(borrower), usdgBefore, "none of the pocket to the flash borrower");
        // Once released, the LPs who were in hold the whole pocket, less nothing but the round trip's rounding.
        vm.warp(block.timestamp + usdgSource.RELEASE());
        (, uint256 lpsAfter) = hook.previewRedeem(hook.balanceOf(partner));
        assertApproxEqAbs(lpsAfter, lpsBefore + pocket, 10, "the pocket reaches the LPs who carried the loan");
    }

    function test_aSeedAfterEveryLpLeftDuringAReleaseGetsItsUsdgBack() public {
        uint256 pocket = 1000e6;
        usdg.mint(address(usdgVault), pocket);
        uint256[] memory ids = new uint256[](1);
        ids[0] = usdgVault.openPocket(address(usdg), address(usdgSource), pocket);
        usdgSource.claimPockets(ids);

        // Every LP leaves inside the release (the partner, the only LP here, moving to a new source, say).
        uint256 all = hook.balanceOf(partner);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(all, 0, 0);
        assertEq(hook.totalSupply(), 0);

        // Once released, someone seeds the pool again and leaves: the proceeds left behind are not its to take, and
        // its own USDG is not lost to them.
        vm.warp(block.timestamp + usdgSource.RELEASE());
        uint256 usdgBefore = usdg.balanceOf(lp);
        vm.prank(lp);
        (uint256 seeded,) = hook.seedLiquidity(100e18, 100e6);
        vm.prank(lp);
        hook.removeReHypothecatedLiquidity(seeded, 0, 0);
        assertApproxEqAbs(usdg.balanceOf(lp), usdgBefore, 1e3, "the seeder gets its USDG back");
    }

    // ------------------------------------------------ vault shares sent to the source
    // A vault's shares transfer, so a holder could send them to the source around an LP's entry and exit: counted as
    // backing, they would let it swap lent shares it cannot redeem for the LPs' float. The source values only the
    // shares it bought itself.

    function test_vaultSharesSentToTheSourceCannotBuyTheLpsFloat() public {
        address holder = makeAddr("vault holder");
        usdg.mint(holder, 20_000e6);
        vm.startPrank(holder);
        usdg.approve(address(usdgVault), type(uint256).max);
        uint256 vaultShares = usdgVault.deposit(20_000e6, holder);
        vm.stopPrank();
        usdgVault.lend(usdgVault.cash()); // every USDG lent: the holder cannot redeem its shares now
        uint256 floatBefore = usdgSource.float();

        // One block: borrow 99 times the pool, enter, send the vault shares to the source, leave, repay.
        frx.mint(holder, 10_000_000e18);
        usdg.mint(holder, 10_000_000e6);
        uint256 usdgBefore = usdg.balanceOf(holder);
        uint256 shares = hook.totalSupply() * 99;
        vm.startPrank(holder);
        frx.approve(address(hook), type(uint256).max);
        usdg.approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        IERC20(address(usdgVault)).transfer(address(usdgSource), vaultShares);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();

        assertLe(usdg.balanceOf(holder), usdgBefore, "no USDG for the vault shares");
        assertApproxEqAbs(usdgSource.float(), floatBefore, 10, "the LPs keep their float");
    }

    // ------------------------------------------------ an LP inside its own unlock
    // Anyone can open a PoolManager unlock and call the hook's add or remove from its callback. The source refuses an
    // exit there on its own: a withdrawal inside an unlock must settle a debt the hook already owes the PoolManager,
    // which only a swap opens. An entry there looks like a swap's input to the source, so the partner's hook refuses LP
    // moves while the PoolManager is unlocked (`UnlockCheckedHook`, one check).

    bytes4 internal constant NOT_A_SWAP = bytes4(keccak256("NotASwap()"));

    function _unlockingLp(ReHypothecationHook on, PoolKey memory key) internal returns (UnlockingLp who) {
        who = new UnlockingLp(manager, on, key);
        frx.mint(address(who), 1_000_000e18);
        usdg.mint(address(who), 1_000_000e6);
    }

    function test_anExitInsideItsOwnUnlockStillWaitsWhileTheVaultSettles() public virtual {
        UnlockingLp who = _unlockingLp(hook, poolKey);
        uint256 shares = hook.totalSupply() / 100;
        who.add(shares);
        usdgVault.setEarliestMaturity(uint40(block.timestamp));
        vm.expectRevert(NOT_A_SWAP);
        who.removeInsideUnlock(shares);
    }

    function test_anExitInsideItsOwnUnlockPaysTheLivePriceAfterAWriteOff() public virtual {
        UnlockingLp who = _unlockingLp(hook, poolKey);
        uint256 shares = hook.totalSupply() / 100;
        who.add(shares);
        usdgVault.lend(40_000e6);
        usdgVault.writeOff(40_000e6);
        vm.expectRevert(NOT_A_SWAP);
        who.removeInsideUnlock(shares);
        (, uint256 fairUsdg) = hook.previewRedeem(shares);
        uint256 usdgBefore = usdg.balanceOf(address(who));
        who.remove(shares);
        assertEq(usdg.balanceOf(address(who)) - usdgBefore, fairUsdg, "outside an unlock the exit pays the live price");
    }

    function test_anLpCannotFakeTheHooksDebt() public virtual {
        UnlockingLp who = _unlockingLp(hook, poolKey);
        uint256 shares = hook.totalSupply() / 100;
        who.add(shares);
        // Crediting the hook in the PoolManager leaves it owed, not owing.
        vm.expectRevert(NOT_A_SWAP);
        who.removeAfterCreditingTheHook(shares);
        // A real swap in the same unlock settles the hook's debt before it returns.
        vm.expectRevert(NOT_A_SWAP);
        who.removeAfterASwap(shares);
    }

    function test_aPartnerHookThatRefusesLpMovesInsideAnUnlockClosesTheEntryTricks() public {
        (UnlockCheckedHook checked, PoolKey memory key) = _checkedPool();
        UnlockingLp who = _unlockingLp(checked, key);
        uint256 shares = checked.totalSupply() / 10;
        // An entry from its own unlock would buy at the cached vault value and deepen swaps by its whole amount.
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.addInsideUnlock(shares);
        // Nor after a swap drained the swap float in the same unlock (the refill round trip).
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.addAfterASwap(shares);

        // Ordinary use is unchanged: LP moves outside an unlock, swaps both ways.
        who.add(shares);
        vm.prank(trader, trader);
        swap(key, true, -1000e18, ZERO_BYTES);
        vm.prank(trader, trader);
        swap(key, false, -500e6, ZERO_BYTES);
        vm.expectRevert(UnlockCheckedHook.LiquidityChangeInsideUnlock.selector);
        who.removeInsideUnlock(shares);
        who.remove(shares);
        assertEq(checked.balanceOf(address(who)), 0);
    }

    /// @dev The same set-up on a hook with the partner's check: its own two sources, gage vault and pool.
    function _checkedPool() internal returns (UnlockCheckedHook checked, PoolKey memory key) {
        MockGageVault vault2 = new MockGageVault(IERC20(address(usdg)));
        registry.record(address(vault2));
        vm.startPrank(partner);
        IGageRehypoSource frx2 =
            IGageRehypoSource(factory.create(IERC20(address(frx)), address(0), partner, partner, 10_000, "frx2"));
        IGageRehypoSource usdg2 =
            IGageRehypoSource(factory.create(IERC20(address(usdg)), address(vault2), partner, partner, 2000, "usdg2"));
        vm.stopPrank();
        address at = address(FLAGS | (uint160(0x7777) << 144));
        deployCodeTo(
            "UnlockCheckedHook.sol:UnlockCheckedHook", abi.encode(address(manager), address(frx2), address(usdg2)), at
        );
        checked = UnlockCheckedHook(payable(at));
        key = PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        manager.initialize(key, PAR);
        vm.startPrank(partner);
        frx2.bind(key);
        usdg2.bind(key);
        usdg2.setKeeper(keeper, true);
        frx.approve(at, type(uint256).max);
        usdg.approve(at, type(uint256).max);
        checked.seedLiquidity(SEED_FRX, SEED_USDG);
        vm.stopPrank();
        (uint160 lo, uint160 hi) = KitBands.around(PAR);
        vm.prank(keeper);
        usdg2.rebalance(lo, hi);
    }

    /// @dev The same hook on OpenZeppelin's own ERC-4626 sources, which hold their tokens themselves, in a pool manager
    /// of its own: with nothing else in it, the after-swap take has no reserve to draw on and the swap reverts
    /// (OpenZeppelin's reserves warning). gage's sources pass the same test in `setUp`'s empty manager.
    function test_plainErc20SourcesNeedTheManagersReserves() public {
        IPoolManager other = new PoolManager(address(this));
        PoolSwapTest router = new PoolSwapTest(other);
        ERC4626YieldSourceMock plain0 = new ERC4626YieldSourceMock(IERC20(address(frx)));
        ERC4626YieldSourceMock plain1 = new ERC4626YieldSourceMock(IERC20(address(usdg)));
        address at = address(FLAGS | (uint160(0x6666) << 144));
        deployCodeTo(
            "ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(other), address(plain0), address(plain1)),
            at
        );
        PoolKey memory plainKey =
            PoolKey(Currency.wrap(address(frx)), Currency.wrap(address(usdg)), FEE, TICK_SPACING, IHooks(at));
        other.initialize(plainKey, PAR);
        vm.startPrank(partner);
        frx.approve(at, type(uint256).max);
        usdg.approve(at, type(uint256).max);
        ReHypothecationERC4626Mock(payable(at)).seedLiquidity(SEED_FRX, SEED_USDG);
        vm.stopPrank();
        vm.startPrank(trader, trader);
        frx.approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.swap(
            plainKey,
            SwapParams({zeroForOne: true, amountSpecified: -1000e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();
    }
}

/// @notice An LP that calls the stock hook from inside a PoolManager unlock it opened itself.
contract UnlockingLp is IUnlockCallback {
    enum Before {
        Nothing,
        CreditTheHook,
        Swap
    }

    IPoolManager internal immutable MANAGER;
    ReHypothecationHook internal immutable HOOK;
    PoolKey internal key;

    constructor(IPoolManager manager, ReHypothecationHook hook, PoolKey memory poolKey) {
        MANAGER = manager;
        HOOK = hook;
        key = poolKey;
        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(hook), type(uint256).max);
    }

    function add(uint256 shares) external {
        HOOK.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
    }

    function remove(uint256 shares) external {
        HOOK.removeReHypothecatedLiquidity(shares, 0, 0);
    }

    function addInsideUnlock(uint256 shares) external {
        _inUnlock(
            Before.Nothing,
            abi.encodeCall(HOOK.addReHypothecatedLiquidity, (shares, type(uint256).max, type(uint256).max))
        );
    }

    function removeInsideUnlock(uint256 shares) external {
        _inUnlock(Before.Nothing, abi.encodeCall(HOOK.removeReHypothecatedLiquidity, (shares, 0, 0)));
    }

    function removeAfterCreditingTheHook(uint256 shares) external {
        _inUnlock(Before.CreditTheHook, abi.encodeCall(HOOK.removeReHypothecatedLiquidity, (shares, 0, 0)));
    }

    function addAfterASwap(uint256 shares) external {
        _inUnlock(
            Before.Swap, abi.encodeCall(HOOK.addReHypothecatedLiquidity, (shares, type(uint256).max, type(uint256).max))
        );
    }

    function removeAfterASwap(uint256 shares) external {
        _inUnlock(Before.Swap, abi.encodeCall(HOOK.removeReHypothecatedLiquidity, (shares, 0, 0)));
    }

    function _inUnlock(Before before, bytes memory call) internal {
        MANAGER.unlock(abi.encode(before, call));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER));
        (Before before, bytes memory call) = abi.decode(data, (Before, bytes));
        if (before == Before.CreditTheHook) {
            MANAGER.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(MANAGER), 1e6);
            MANAGER.settleFor(address(HOOK));
        } else if (before == Before.Swap) {
            MANAGER.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
        }
        (bool ok, bytes memory ret) = address(HOOK).call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

/// @notice A stand-in for the generation deployer's record of Intent factories (`IIntentFactoryRegistry`): a source
/// accepts only a vault whose factory is recorded.
contract FactoryRegistryStandIn {
    mapping(address => bool) public isFactory;

    function record(address factory) external {
        isFactory[factory] = true;
    }
}
