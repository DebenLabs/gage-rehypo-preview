// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ReHypothecationERC4626Mock} from "@openzeppelin/uniswap-hooks/src/mocks/general/ReHypothecationERC4626Mock.sol";
import {IGageRehypoSource, FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {RehypoSourceSettings} from "../script/RehypoSource.s.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
// Imported so the tests can deploy it by name (`deployCodeTo`).
import {RangedReHypothecationMock} from "./mocks/RangedReHypothecationMocks.sol";

interface IGageRehypoSourceFactoryPriced {
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external returns (address source);
}

interface IGageRehypoSourcePriced is IGageRehypoSource {
    function reportAt() external view returns (uint40);
    function rebalanceAt(bytes calldata report) external;
    function centre() external view returns (uint160);
    function heldUntil() external view returns (uint40);
}

/// @notice A Robinhood Stock Token stand-in: a display multiplier and a corporate-action pause.
contract StockStandIn is MockERC20 {
    uint256 public uiMultiplier = 1e18;
    bool public oraclePaused;

    constructor() MockERC20("NVIDIA", "NVDA", 18) {}

    function setUiMultiplier(uint256 m) external {
        uiMultiplier = m;
    }
}

/// @notice `NuntiusPriceSource`'s surface with its refusals, in this kit's compiler: the report is the price (eight
/// decimals) and its time; it refuses a report older than five minutes or a paused token. The signed path itself is
/// tested in `contracts/test/rehypo/GageRehypoSourceNext.t.sol` against the real contract.
contract SignedPriceStandIn {
    address public immutable USDG;
    bool public paused;

    error OraclePaused(address token);
    error StalePrice(address token, uint256 timestamp);

    constructor(address usdg) {
        USDG = usdg;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function assetOf(address) external pure returns (bytes32, uint32, uint8, uint8, bool) {
        return (keccak256("NVDA/USD"), 5 minutes, 1, 18, true);
    }

    function valueOf(address token, uint256 amount, bytes calldata report) external view returns (uint256, uint256) {
        if (paused) revert OraclePaused(token);
        (uint256 price, uint256 at) = abi.decode(report, (uint256, uint256));
        if (at + 5 minutes < block.timestamp || at > block.timestamp + 1 minutes) revert StalePrice(token, at);
        return (Math.mulDiv(amount, price * 1e6, 1e26), at);
    }
}

/// @notice The moving band on OpenZeppelin's own ERC-4626 rehypothecation hook (design 2.3, proof bullets): an
/// NVDA/USDG pool whose two sources centre their band on a signed price, NVDA float-only and USDG lent through a gage
/// vault stand-in. Rounds pushed 5%, 20% and 99% off the signed centre on a thin float, a false centre 10% off, a
/// refused report, and a multiplier change mid-stretch; each on a full-range hook and on a +-1% range declared 200
/// ticks wide. The pass bar is the stable pair's: under a fifteenth of the edge depth per round, a quarter per stretch.
contract RehypoSourcePricedPlugTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev NVDA at $180, eight decimals.
    uint256 internal constant PRICE = 180e8;
    uint256 internal constant SEED_NVDA = 555e18;
    uint256 internal constant SEED_USDG = 100_000e6;
    int256 internal constant ROUND_BAR = 666;
    int256 internal constant STRETCH_BAR = 2500;

    StockStandIn internal nvda;
    MockERC20 internal usdg;
    MockGageVault internal usdgVault;
    SignedPriceStandIn internal prices;
    IGageRehypoSourceFactoryPriced internal factory;
    IGageRehypoSourcePriced internal nvdaSource;
    IGageRehypoSourcePriced internal usdgSource;
    ReHypothecationERC4626Mock internal hook;
    PoolKey internal poolKey;
    /// @dev The pool's sqrt price at $180: NVDA (currency0) for USDG (currency1).
    uint160 internal par;

    address internal partner = makeAddr("partner safe");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    address internal vaultDepositor = makeAddr("vault depositor");

    function setUp() public {
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();
        nvda = StockStandIn(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("RehypoSourcePricedPlug.t.sol:StockStandIn", "", address(nvda));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        usdgVault = new MockGageVault(IERC20(address(usdg)));
        prices = new SignedPriceStandIn(address(usdg));
        par = uint160(Math.sqrt(Math.mulDiv(180e6, 1 << 192, 1e18)));
    }

    // ---------------------------------------------------------------- the stack

    /// @dev Both sources priced, declared `rangeTicks` wide, on OpenZeppelin's hook: full range when `half` is zero,
    /// else a range `half` ticks either side of the pool's price at each swap.
    function _stack(uint24 rangeTicks, int24 half, uint160 hookSalt) internal {
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        factory = IGageRehypoSourceFactoryPriced(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(manager), address(registry), address(prices)))
        );
        RehypoSourceSettings memory s = RehypoSourceSettings(rangeTicks, address(prices), address(nvda), 100, 500);
        vm.startPrank(partner);
        nvdaSource = IGageRehypoSourcePriced(
            factory.create(IERC20(address(nvda)), address(0), partner, partner, 10_000, s, "n")
        );
        usdgSource = IGageRehypoSourcePriced(
            factory.create(IERC20(address(usdg)), address(usdgVault), partner, partner, 2000, s, "u")
        );
        vm.stopPrank();

        address at = address(FLAGS | (hookSalt << 144));
        if (half == 0) {
            deployCodeTo(
                "ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
                abi.encode(address(manager), address(nvdaSource), address(usdgSource)),
                at
            );
        } else {
            deployCodeTo(
                "RangedReHypothecationMocks.sol:RangedReHypothecationMock",
                abi.encode(address(manager), address(nvdaSource), address(usdgSource), true, half, int24(0)),
                at
            );
        }
        hook = ReHypothecationERC4626Mock(payable(at));
        poolKey = PoolKey(Currency.wrap(address(nvda)), Currency.wrap(address(usdg)), 100, int24(1), IHooks(at));
        manager.initialize(poolKey, par);
        vm.startPrank(partner);
        nvdaSource.bind(poolKey);
        usdgSource.bind(poolKey);
        nvdaSource.setKeeper(keeper, true);
        usdgSource.setKeeper(keeper, true);
        vm.stopPrank();

        address[2] memory holders = [partner, trader];
        for (uint256 i; i < holders.length; ++i) {
            nvda.mint(holders[i], 100_000e18);
            usdg.mint(holders[i], 10_000_000e6);
            vm.startPrank(holders[i]);
            nvda.approve(at, type(uint256).max);
            usdg.approve(at, type(uint256).max);
            nvda.approve(address(swapRouter), type(uint256).max);
            usdg.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        // As a live PoolManager does, the manager holds other pools' tokens: the hook's after-swap take of a swap's
        // input runs before the swapper pays, so a fresh manager holding only the floats would refuse it.
        nvda.mint(address(manager), 100_000e18);
        usdg.mint(address(manager), 10_000_000e6);
        vm.prank(partner);
        hook.seedLiquidity(SEED_NVDA, SEED_USDG);
        _rebalanceBoth(PRICE);
    }

    function _report(uint256 price) internal view returns (bytes memory) {
        return abi.encode(price, block.timestamp);
    }

    /// @dev The keeper's pass on a fresh report: one signed after the last each source centred on, a second later when
    /// the last was signed this second.
    function _rebalanceBoth(uint256 price) internal {
        uint256 last = Math.max(usdgSource.reportAt(), nvdaSource.reportAt());
        if (block.timestamp <= last) vm.warp(last + 1);
        vm.startPrank(keeper);
        usdgSource.rebalanceAt(_report(price));
        nvdaSource.rebalanceAt(_report(price));
        vm.stopPrank();
    }

    /// @dev The keeper's pass that a refused report or a multiplier hold may stop: it then sends nothing.
    function tryRebalanceBoth(uint256 price) external {
        require(msg.sender == address(this), "self only");
        _rebalanceBoth(price);
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
    }

    function _sqrtAt(uint256 bps) internal view returns (uint160) {
        return uint160(Math.mulDiv(par, Math.sqrt(bps * 1e14), 1e9));
    }

    function _edge() internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(usdgSource.totalAssets(), 2000, 10_000), 100, 10_000);
    }

    /// @dev Tokens plus claims, NVDA at `nvdaPrice` (eight decimals) a token.
    function _value(address who, uint256 nvdaPrice) internal view returns (int256) {
        uint256 n = nvda.balanceOf(who) + manager.balanceOf(who, uint256(uint160(address(nvda))));
        uint256 u = usdg.balanceOf(who) + manager.balanceOf(who, uint256(uint160(address(usdg))));
        return int256(u + Math.mulDiv(n, nvdaPrice * 1e6, 1e26));
    }

    function _systemValue() internal view returns (int256 v) {
        address[7] memory all = [
            trader, partner, vaultDepositor, address(hook), address(nvdaSource), address(usdgSource), address(usdgVault)
        ];
        for (uint256 i; i < all.length; ++i) {
            v += _value(all[i], PRICE);
        }
    }

    function _swapTo(bool zeroForOne, uint160 limit) internal {
        vm.prank(trader, trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(50_000e18) : -int256(9_000_000e6),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev One swap, external so a refused one can be caught.
    function swapTo(bool zeroForOne, uint160 limit) external {
        require(msg.sender == address(this), "self only");
        _swapTo(zeroForOne, limit);
    }

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

    /// @dev The 29 October pusher: the vault's free cash taken, the LPs gone until the USDG float is a sliver, the price
    /// pushed to `pushed`, the rest of what can leave gone, the vault's cash back.
    function _pushOnASliver(uint160 pushed) internal returns (int256 push) {
        usdg.mint(vaultDepositor, 20_000e6);
        vm.startPrank(vaultDepositor);
        usdg.approve(address(usdgVault), type(uint256).max);
        usdgVault.deposit(20_000e6, vaultDepositor);
        vm.stopPrank();
        usdgVault.lend(80_000e6);
        vm.prank(vaultDepositor);
        usdgVault.withdraw(20_000e6, vaultDepositor, vaultDepositor);
        _exit(_sharesTheSourceCanPay() * 99_999 / 100_000);
        int256 start = _value(trader, PRICE);
        _swapTo(pushed < par, pushed);
        push = _value(trader, PRICE) - start;
        assertEq(_price(), pushed, "pushed off the signed centre");
        _exit(_sharesTheSourceCanPay());
        vm.prank(vaultDepositor);
        usdgVault.deposit(20_000e6, vaultDepositor);
    }

    function _tradeBack() internal returns (int256 back) {
        int256 start = _value(trader, PRICE);
        try this.swapTo(_price() > par, par) {} catch {}
        back = _value(trader, PRICE) - start;
    }

    /// @dev A round `bps` of the signed price, the keeper's pass on an honest report, the trade back.
    function _round(uint256 bps) internal returns (int256 bpsOfEdge) {
        uint256 snapshot = vm.snapshotState();
        int256 before = _systemValue();
        uint256 edge = _edge();
        int256 push = _pushOnASliver(_sqrtAt(bps));
        _rebalanceBoth(PRICE);
        int256 back = _tradeBack();
        bpsOfEdge = (push + back) * 10_000 / int256(edge);
        console2.log(
            string.concat(
                "  priced round ",
                vm.toString(bps),
                " push=",
                vm.toString(push),
                " back=",
                vm.toString(back),
                " netBps=",
                vm.toString(bpsOfEdge)
            )
        );
        assertApproxEqAbs(_systemValue() - 20_000e6, before, 1e5, "value moves between these accounts and nowhere else");
        vm.revertToStateAndDelete(snapshot);
    }

    function _rounds(string memory label) internal {
        uint256[6] memory at = [uint256(9500), 8000, 100, 10_500, 12_000, 19_900];
        int256 worst = type(int256).min;
        for (uint256 i; i < at.length; ++i) {
            int256 bps = _round(at[i]);
            if (bps > worst) worst = bps;
        }
        console2.log(string.concat(label, " WORST PRICED ROUND bps ", vm.toString(worst)));
        assertLe(worst, ROUND_BAR, "under a fifteenth of the edge per round, 5%, 20% and 99% off the signed centre");
    }

    // ---------------------------------------------------------------- rounds off the signed centre

    function test_priced_roundsOffTheSignedCentre_fullRange() public {
        _stack(0, 0, 0x5101);
        _rounds("full ");
    }

    function test_priced_roundsOffTheSignedCentre_onePercentRange() public {
        _stack(200, 100, 0x5102);
        _rounds("+-1% on 200 ");
    }

    // ---------------------------------------------------------------- a false centre

    /// @dev Signed reports 10% under the market for three hours: the centre walks there at its hourly bound, a pusher
    /// parks the pool at the false price, the keeper reopens it in full inside the false band, and the trade back to the
    /// market price takes what the swap floats hold, and no more.
    function _falseCentre(uint24 rangeTicks, int24 half, uint160 salt) internal {
        _stack(rangeTicks, half, salt);
        int256 before = _systemValue();
        uint256 falsePrice = PRICE * 90 / 100;
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _rebalanceBoth(falsePrice);
        }
        assertApproxEqRel(
            usdgSource.centre(), _sqrtAt(9000), 1e12, "after three hours the centre sits on the false price"
        );
        _swapTo(true, _sqrtAt(9000));
        _rebalanceBoth(falsePrice);
        uint256 usdgOpen = usdgSource.swapFloat();
        uint256 nvdaOpen = nvdaSource.swapFloat();
        int256 lpsBefore = _value(address(nvdaSource), PRICE) + _value(address(usdgSource), PRICE);
        int256 back = _tradeBack();
        int256 lpLoss = lpsBefore - _value(address(nvdaSource), PRICE) - _value(address(usdgSource), PRICE);
        uint256 open = usdgOpen + Math.mulDiv(nvdaOpen, PRICE * 1e6, 1e26);
        console2.log(
            string.concat(
                "false centre on ",
                vm.toString(rangeTicks),
                ": trade back ",
                vm.toString(back),
                " lpLoss ",
                vm.toString(lpLoss),
                " swap floats ",
                vm.toString(open)
            )
        );
        assertLe(lpLoss, int256(open), "a false centre costs the LPs no more than the swap floats");
        assertApproxEqAbs(_systemValue(), before, 1e5, "and mints nothing");
    }

    function test_priced_falseCentre_fullRange() public {
        _falseCentre(0, 0, 0x5201);
    }

    function test_priced_falseCentre_onePercentRange() public {
        _falseCentre(200, 100, 0x5202);
    }

    // ---------------------------------------------------------------- refusals and the multiplier

    /// @dev A refused report (stale, or the token paused) stops the keeper's pass and nothing else: swaps run on what
    /// is open.
    function test_priced_aRefusedReportLeavesSwapsRunning() public {
        _stack(0, 0, 0x5301);
        uint256 open = usdgSource.swapFloat();
        bytes memory stale = abi.encode(PRICE, block.timestamp - 6 minutes);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SignedPriceStandIn.StalePrice.selector, address(nvda), block.timestamp - 6 minutes)
        );
        usdgSource.rebalanceAt(stale);
        prices.setPaused(true);
        bytes memory fresh = _report(PRICE);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SignedPriceStandIn.OraclePaused.selector, address(nvda)));
        usdgSource.rebalanceAt(fresh);
        assertEq(usdgSource.swapFloat(), open, "the swap float stays where it was");
        uint256 before = usdg.balanceOf(trader);
        _swapTo(true, _sqrtAt(9990));
        assertGt(usdg.balanceOf(trader), before, "and swaps go on");
    }

    /// @dev A stretch back from 50% under the signed centre in steps between the keeper's passes, ten minutes apart,
    /// with a 2% multiplier change after the second step: the pass that sees it holds, an hour of passes are refused,
    /// trades go on, and the stretch stays under a quarter of the edge.
    function _multiplierStretch(uint24 rangeTicks, int24 half, uint160 salt) internal {
        _stack(rangeTicks, half, salt);
        int256 before = _systemValue();
        uint256 edge = _edge();
        int256 net = _pushOnASliver(_sqrtAt(5000));
        uint256 held;
        for (uint256 pass; pass < 40 && _price() < par; ++pass) {
            if (pass == 2) nvda.setUiMultiplier(1.02e18);
            vm.warp(block.timestamp + 10 minutes);
            try this.tryRebalanceBoth(PRICE) {}
            catch {
                ++held;
            }
            int256 start = _value(trader, PRICE);
            try this.swapTo(false, uint160(Math.min(uint256(_price()) * 103 / 100, par))) {} catch {}
            net += _value(trader, PRICE) - start;
        }
        int256 bps = net * 10_000 / int256(edge);
        console2.log(
            string.concat(
                "multiplier stretch on ",
                vm.toString(rangeTicks),
                ": netBps ",
                vm.toString(bps),
                " passes held ",
                vm.toString(held)
            )
        );
        assertGe(held, 5, "an hour of passes are held after the change");
        assertLe(bps, STRETCH_BAR, "under a quarter of the edge per stretch");
        assertApproxEqAbs(_systemValue() - 20_000e6, before, 1e5, "the stretch mints nothing");
    }

    function test_priced_multiplierChangeMidStretch_fullRange() public {
        _multiplierStretch(0, 0, 0x5401);
    }

    function test_priced_multiplierChangeMidStretch_onePercentRange() public {
        _multiplierStretch(200, 100, 0x5402);
    }
}
