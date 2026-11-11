// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {
    RehypoSource,
    IGageRehypoSource,
    IGageRehypoSourceFactory,
    RehypoSourceSettings
} from "../script/RehypoSource.s.sol";
import {StablePriceStandIn} from "./RehypoSourceRepeat.t.sol";
import {FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {StandingPosition} from "../src/StandingAnchoredHook.sol";

/// @notice What an LP's exit now reads on a source beyond the set-up's interface.
interface IExitingSource {
    function totalAssets() external view returns (uint256);
    function float() external view returns (uint256);
    function swapFloat() external view returns (uint256);
    function exitNow(uint256 id) external;
}

/// @notice A stand-in for the chain's exit desk (`IntentExitDesk`) as a rehypo source asks it: a holder
/// commits vault shares it has approved, and the desk owes it nothing until a sale.
contract ExitDeskStandIn {
    struct Exit {
        uint256 shares;
        uint256 id;
        uint64 nonce;
    }

    mapping(address vault => mapping(address owner => Exit)) public exits;

    error InvalidAmount();

    function exitNow(address vault, uint256 shares, uint256 id) external {
        if (shares == 0 || shares > IERC20(vault).allowance(msg.sender, address(this))) revert InvalidAmount();
        Exit storage e = exits[vault][msg.sender];
        e.shares = shares;
        if (id != 0) (e.id, e.nonce) = (id, e.nonce + 1);
    }

    function owed(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice The kit's vault stand-in as its own Intent factory names the chain's exit desk.
contract DeskedVault is MockGageVault {
    address public immutable exitDesk;

    constructor(IERC20 asset_, address desk) MockGageVault(asset_) {
        exitDesk = desk;
    }
}

/// @notice A keeper's day on a pool the set-up script stood up on a standing hook (`RehypoSource.setUpStandingPool`,
/// a pegged frxUSD/USDG pool on a local PoolManager), end to end: the keeper's moves, all sent to the hook, with swaps
/// between them, an LP's entry and exit, a take-out, and an LP's exit now. After every step: what the partner, the LPs
/// and the trader hold with the pool's backing is what they started with, to the dust a rounding leaves; the hook stays
/// the one keeper of both sources; every move leaves the position out; and of the swaps between two moves only the
/// first, which places the position, touches a source.
contract StandingKeeperDayTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;
    /// @dev A keeper pass every half hour, a day of them.
    uint256 internal constant PASSES = 48;

    MockERC20 internal frx;
    MockERC20 internal usdg;
    DeskedVault internal usdgVault;
    ExitDeskStandIn internal desk;
    RehypoSource internal script;
    RehypoSource.Plugged internal p;
    StandingPosition internal hook;
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("a second LP");
    uint256 internal everything0;
    uint256 internal everything1;
    uint256 internal steps;
    /// @dev The middle of the range the first move places the position on: one frxUSD for one USDG.
    int24 internal parity;

    function setUp() public {
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();
        frx = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), address(frx));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        desk = new ExitDeskStandIn();
        usdgVault = new DeskedVault(IERC20(address(usdg)), address(desk));
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        script = new RehypoSource();
        StablePriceStandIn prices = new StablePriceStandIn(address(usdg));
        address[3] memory who = [address(this), trader, lp];
        for (uint256 i; i < who.length; ++i) {
            frx.mint(who[i], 1_000_000e18);
            usdg.mint(who[i], 1_000_000e6);
        }
        // The pool: pegged, a +-0.25% range, a 20% float either side, USDG lent through a gage vault.
        p = script.setUpStandingPool(
            RehypoSource.Pool({
                factory: IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(prices))),
                lend: IERC20(address(usdg)),
                vault: address(usdgVault),
                floatBps: 2000,
                floatOnly: IERC20(address(frx)),
                floatVault: address(0),
                floatOnlyBps: 0,
                keeper: keeper,
                seedLend: SEED_USDG,
                seedFloat: SEED_FRX,
                salt: "a keeper day",
                settings: RehypoSourceSettings(50, address(prices), address(frx), 50, 100),
                price8: 1e8,
                failsafeBps: 0,
                pegBps: 50
            })
        );
        hook = StandingPosition(payable(address(p.hook)));
        for (uint256 i = 1; i < who.length; ++i) {
            vm.startPrank(who[i]);
            frx.approve(address(swapRouter), type(uint256).max);
            usdg.approve(address(swapRouter), type(uint256).max);
            frx.approve(address(hook), type(uint256).max);
            usdg.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
        (everything0, everything1) = _everything();
    }

    // ---------------------------------------------------------------- reads

    /// @dev The fees the position has earned and not collected: the hook's count of its position leaves them out.
    function _uncollected() internal view returns (uint256 fees0, uint256 fees1) {
        (uint128 liquidity, int24 lower, int24 upper) = hook.position();
        if (liquidity == 0) return (0, 0);
        PoolId id = p.key.toId();
        (, uint256 last0, uint256 last1) = manager.getPositionInfo(id, address(hook), lower, upper, bytes32(0));
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, lower, upper);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, 1 << 128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, 1 << 128);
        }
    }

    /// @dev The LPs' backing of each coin: both sources, the position and its fees.
    function _backing() internal view returns (uint256 b0, uint256 b1) {
        (uint256 in0, uint256 in1) = hook.positionAmounts();
        (uint256 f0, uint256 f1) = _uncollected();
        b0 = IExitingSource(address(p.floatSource)).totalAssets() + in0 + f0;
        b1 = IExitingSource(address(p.lendSource)).totalAssets() + in1 + f1;
    }

    function _everything() internal view returns (uint256 e0, uint256 e1) {
        (e0, e1) = _backing();
        address[3] memory who = [address(this), trader, lp];
        for (uint256 i; i < who.length; ++i) {
            e0 += frx.balanceOf(who[i]);
            e1 += usdg.balanceOf(who[i]);
        }
    }

    /// @dev After each step: nothing left the system but rounding dust, the hook is still the sources' one keeper of
    /// the three accounts here, and the hook holds no coin of its own.
    function _check(string memory when) internal {
        (uint256 e0, uint256 e1) = _everything();
        ++steps;
        assertApproxEqAbs(e0, everything0, 1e4 * steps, string.concat("frxUSD, after ", when));
        assertApproxEqAbs(e1, everything1, 4 * steps, string.concat("USDG, after ", when));
        assertLe(e0, everything0, when);
        assertLe(e1, everything1, when);
        assertEq(frx.balanceOf(address(hook)) + usdg.balanceOf(address(hook)), 0, when);
        assertTrue(p.lendSource.isKeeper(address(hook)) && p.floatSource.isKeeper(address(hook)), when);
        assertFalse(p.lendSource.isKeeper(keeper) || p.floatSource.isKeeper(keeper), when);
    }

    function _liquidity() internal view returns (uint128 liquidity) {
        (liquidity,,) = hook.position();
    }

    // ---------------------------------------------------------------- moves

    /// @dev The keeper's pass: one call to the hook with a fresh signed price.
    function _pass() internal {
        vm.prank(keeper);
        hook.rebalanceAt(abi.encode(uint256(1e8), block.timestamp));
    }

    function _swap(bool sellFrx, uint256 amount) internal {
        vm.prank(trader);
        swapRouter.swap(
            p.key,
            SwapParams({
                zeroForOne: sellFrx,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: sellFrx ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Which way the next swap goes: either way near the peg, and back towards it once the price is ten ticks
    /// off, as a pegged pair's arbitrage brings it. A price left to walk out of the sources' band stops their float
    /// for swaps, and a pass then places nothing: `test_farPastTheBandThePositionTradesBackAndAPassStopsSwaps`.
    function _sells(uint256 x) internal view returns (bool sellFrx) {
        (, int24 tick,,) = manager.getSlot0(p.key.toId());
        if (tick > parity + 10) return true;
        if (tick < parity - 10) return false;
        return x % 2 == 0;
    }

    /// @dev What a recorded stretch touched of either source or the vault.
    function _sourceAccesses(Vm.AccountAccess[] memory accesses) internal view returns (uint256 n) {
        for (uint256 i; i < accesses.length; ++i) {
            address a = accesses[i].account;
            if (a == address(p.lendSource) || a == address(p.floatSource) || a == address(usdgVault)) ++n;
        }
    }

    // ---------------------------------------------------------------- the day

    function test_aKeeperDayOnAStandingPoolTheSetUpScriptStoodUp() public {
        vm.pauseGasMetering();
        assertEq(_liquidity(), 0, "nothing in the pool before the keeper's first move");
        _pass();
        assertEq(_liquidity(), 0, "nor after it: the move places nothing");
        parity = (hook.getTickLower() + hook.getTickUpper()) / 2;
        _check("the first move");
        uint256 worthAtStart = _worth(address(this));
        uint256 entered;

        for (uint256 i; i < PASSES; ++i) {
            // Three swaps between two passes, either way, from a few dollars to a few thousand. The first places the
            // position, through the sources; the two after it find it in place and ask no source.
            for (uint256 j; j < 3; ++j) {
                uint256 x = uint256(keccak256(abi.encode(i, j)));
                bool sellFrx = _sells(x);
                uint256 dollars = 5 + (x >> 8) % 3000;
                if (j == 1) vm.startStateDiffRecording();
                _swap(sellFrx, sellFrx ? dollars * 1e18 : dollars * 1e6);
                if (j == 0) assertGt(_liquidity(), 0, "the first swap after a move places the position");
            }
            assertEq(_sourceAccesses(vm.stopAndReturnStateDiff()), 0, "swaps on the position in place touch no source");
            _check("swaps");

            if (i == 10) {
                // An LP enters with a tenth of the supply: the position comes out, and a swap places it again.
                entered = hook.totalSupply() / 10;
                vm.prank(lp);
                hook.addReHypothecatedLiquidity(entered, type(uint256).max, type(uint256).max);
                assertEq(_liquidity(), 0);
                _check("an LP entry");
            }
            if (i == 20) {
                vm.prank(lp);
                hook.removeReHypothecatedLiquidity(entered / 2, 0, 0);
                _check("an LP exit");
            }
            if (i == 30) {
                // An LP-share holder takes the position out; nobody else may.
                vm.expectRevert(StandingPosition.NotKeeperOrHolder.selector);
                vm.prank(trader);
                hook.takeOut();
                vm.prank(lp);
                hook.takeOut();
                assertEq(_liquidity(), 0);
                _check("a take-out");
            }
            if (i == 40) _exitNow();

            vm.warp(block.timestamp + 30 minutes);
            if (i == 40) {
                // The vault is repaid before the next pass, which lends the float's excess again.
                usdg.mint(address(usdgVault), usdgVault.performingPrincipal());
                usdgVault.repay(usdgVault.performingPrincipal(), 0);
            }
            _pass();
            assertEq(_liquidity(), 0, string.concat("every pass leaves the position out, pass ", vm.toString(i)));
            _check("a keeper pass");
        }

        // The day's fees are the LPs': the first LP's shares are worth no less than at the start.
        assertGe(_worth(address(this)), worthAtStart, "the LP that stayed all day lost nothing");
        // Everyone leaves: the last exit takes the position out for good.
        uint256 rest = hook.balanceOf(lp);
        vm.prank(lp);
        hook.removeReHypothecatedLiquidity(rest, 0, 0);
        hook.removeReHypothecatedLiquidity(hook.balanceOf(address(this)), 0, 0);
        assertEq(hook.totalSupply(), 0);
        assertEq(_liquidity(), 0, "nothing left in the pool");
        _check("everyone left");
        vm.resumeGasMetering();
    }

    /// @notice A trader that buys the pool's frxUSD out with no price limit leaves the price far past the range, the
    /// position still in the pool, all USDG. Left there, the pool recovers on its own: a sale of frxUSD walks the price
    /// back into the range and trades on the position, no source asked. A keeper's pass at that price instead takes
    /// the position out, and no swap can place it again, since each source's band refuses its float to swaps that far
    /// out: the pass does not revert, nothing is lost, and swaps stop both ways until the partner's rescue, as on the
    /// kit's other anchored hooks (docs/rehypo-source.md, "Limits and risks").
    function test_farPastTheBandThePositionTradesBackAndAPassStopsSwaps() public {
        _pass();
        _swap(false, 5e6);
        _swap(false, 60_000e6);
        (, int24 tick,,) = manager.getSlot0(p.key.toId());
        assertGt(tick, hook.getTickUpper() + 100_000, "far past the range");
        assertGt(_liquidity(), 0, "the position is still in the pool");
        _check("a swap past the range");

        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        _swap(true, 10_000e18);
        assertEq(_sourceAccesses(vm.stopAndReturnStateDiff()), 0, "the trade back asks no source");
        (, tick,,) = manager.getSlot0(p.key.toId());
        assertTrue(tick >= hook.getTickLower() && tick < hook.getTickUpper(), "back in the range");
        _check("the trade back");
        vm.warp(block.timestamp + 30 minutes);
        _pass();
        _swap(true, 5e18);
        assertGt(_liquidity(), 0, "and after the next pass a swap places as usual");
        vm.revertToStateAndDelete(snapshot);

        vm.warp(block.timestamp + 30 minutes);
        _pass();
        assertEq(_liquidity(), 0, "the pass took the position out");
        _check("a pass far out of the band");
        bytes memory stopped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(stopped);
        this.swapAsTrader(true, 1e18);
        vm.expectRevert(stopped);
        this.swapAsTrader(false, 1e6);
    }

    function swapAsTrader(bool sellFrx, uint256 amount) external {
        _swap(sellFrx, amount);
    }

    /// @dev What `who`'s shares are worth, both coins at a dollar, in USDG's units, uncollected fees counted.
    function _worth(address who) internal view returns (uint256) {
        uint256 shares = hook.balanceOf(who);
        (uint256 a0, uint256 a1) = hook.previewRedeem(shares);
        (uint256 f0, uint256 f1) = _uncollected();
        uint256 supply = hook.totalSupply() + 1e6;
        return (a0 + FullMath.mulDiv(f0, shares, supply)) / 1e12 + a1 + FullMath.mulDiv(f1, shares, supply);
    }

    /// @dev An LP's exit now on the lent side, the vault's cash all on loan: the LP takes the position out first, then
    /// asks the source, which commits at the desk the vault shares its float cannot cover of the LP's share. Asked with
    /// the position still in the pool, the source counts neither the LP's part of it nor the float it would bring back,
    /// and commits more shares than the exit needs.
    function _exitNow() internal {
        usdgVault.lend(usdgVault.cash());
        IExitingSource source = IExitingSource(address(p.lendSource));
        uint256 supply = hook.totalSupply();
        uint256 mine = hook.balanceOf(address(this));

        uint256 snapshot = vm.snapshotState();
        source.exitNow(0);
        (uint256 early,,) = desk.exits(address(usdgVault), address(source));
        vm.revertToStateAndDelete(snapshot);

        hook.takeOut();
        _check("the take-out before an exit now");
        uint256 claim = FullMath.mulDiv(source.totalAssets(), mine, supply);
        uint256 cash = source.float();
        assertGt(claim, cash, "the float cannot pay this LP's share, and the vault has nothing free");
        source.exitNow(0);
        (uint256 committed,,) = desk.exits(address(usdgVault), address(source));
        assertEq(committed, usdgVault.previewWithdraw(claim - cash), "what the LP's share needs beyond the float");
        assertGt(early, committed, "asked with the position in the pool, more shares than the exit needs");
        _check("an exit now");
    }
}
