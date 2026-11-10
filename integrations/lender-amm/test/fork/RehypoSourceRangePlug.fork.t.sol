// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ReHypothecationERC4626Mock} from "@openzeppelin/uniswap-hooks/src/mocks/general/ReHypothecationERC4626Mock.sol";
import {IGageRehypoSource, FactoryRegistryStandIn} from "../RehypoSourcePlug.t.sol";
import {MockGageVault} from "../mocks/MockGageVault.sol";
import {KitBands} from "../utils/KitBands.sol";
// Imported so the tests can deploy it by name (`deployCodeTo`).
import {RangedReHypothecationMock, MultiRangeReHypothecationMock} from "../mocks/RangedReHypothecationMocks.sol";
import {RehypoSourceSettings} from "../../script/RehypoSource.s.sol";

interface IGageRehypoSourceFactoryFailsafe {
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external returns (address source);
}

interface IGageRehypoSourceFactoryNext {
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

interface IGageRehypoSourceNext is IGageRehypoSource {
    function RANGE_TICKS() external view returns (uint24);
    function MIN_RANGE_TICKS() external view returns (uint24);
    function CONCENTRATION_TICKS() external view returns (uint24);
}

/// @notice The 8 November concentrated-JIT rounds against the next rehypo source generation (design 2.1-2.2): each
/// source declares the narrowest range its hook commits to (`RANGE_TICKS`), both the float-only frxUSD side and the
/// lent USDG side are rebalanced, and past the band a narrow source caps its swap float at the full-range cap times
/// the range's concentration. The pass bar is the brief's: under a fifteenth of the edge depth per round, under a
/// quarter per stretch, for every range shape at or above the declared width. A source declared full range keeps the
/// full-range numbers, and a narrow hook on it still breaches: the declaration is what holds the bound.
/// @dev Robinhood Chain mainnet's own state when `LENDER_AMM_MAINNET_FORK_RPC` is set (the live PoolManager, real USDG
/// and frxUSD; `LENDER_AMM_MAINNET_FORK_BLOCK` pins the block). Without it, the same rounds run on a fresh PoolManager
/// of the same v4-core and stand-in tokens deployed at mainnet's token addresses, so CI proves the arithmetic without an RPC. Either way the gage
/// USDG vault and the deployer's record are stand-ins (`MockGageVault`, `FactoryRegistryStandIn`), gage's sources come
/// from `contracts/` (`forge build src/rehypo/GageRehypoSourceFactory.sol` there first), and nothing is sent to a chain.
contract RehypoSourceRangeForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRXUSD = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev One frxUSD for one USDG: a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;
    /// @dev The keeper's band for frxUSD/USDG, `RehypoSource.s.sol` `band()`: one for one +/-0.5%.
    uint160 internal constant BAND_LO = 79_029_843_899_059_723_247_256;
    uint160 internal constant BAND_HI = 79_425_985_949_584_624_389_260;
    /// @dev The pass bar, in basis points of the edge depth: a fifteenth per round, a quarter per stretch.
    int256 internal constant ROUND_BAR = 666;
    int256 internal constant STRETCH_BAR = 2500;
    /// @dev The narrowest range a source may declare (`GageRehypoSource.MIN_RANGE_TICKS`, provisional): the keeper's
    /// +-0.5% band.
    uint24 internal constant FLOOR = 100;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    MockGageVault internal usdgVault;
    IGageRehypoSourceFactoryNext internal factory;
    IGageRehypoSourceNext internal frxSource;
    IGageRehypoSourceNext internal usdgSource;
    ReHypothecationERC4626Mock internal hook;
    PoolKey internal poolKey;
    uint24 internal fee;
    bool internal forked;
    /// @dev Swaps OpenZeppelin's hook refused for want of liquidity past the band.
    uint256 internal frozen;
    /// @dev The vault failsafe (2.5) the next stack's sources carry; zero for none.
    uint16 internal failsafeBps;

    uint160 internal bandLo = BAND_LO;
    uint160 internal bandHi = BAND_HI;
    address internal partner = makeAddr("partner safe");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");
    address internal vaultDepositor = makeAddr("vault depositor");

    function setUp() public {
        string memory rpc = vm.envOr("LENDER_AMM_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc, vm.envOr("LENDER_AMM_MAINNET_FORK_BLOCK", uint256(108_997_079)));
            assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
            assertGt(address(POOL_MANAGER).code.length, 0, "the live PoolManager has code at the fork block");
            assertGt(USDG.code.length, 0, "USDG has code at the fork block");
            assertGt(FRXUSD.code.length, 0, "frxUSD has code at the fork block");
            forked = true;
            manager = POOL_MANAGER;
        } else {
            manager = new PoolManager(address(this));
            deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), USDG);
            deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), FRXUSD);
        }
        router = new PoolSwapTest(manager);
        usdgVault = new MockGageVault(IERC20(USDG));
    }

    // ---------------------------------------------------------------- the stack

    function _settings(uint24 rangeTicks) internal pure returns (RehypoSourceSettings memory s) {
        s.rangeTicks = rangeTicks;
    }

    /// @dev The factory and both sources, declared `rangeTicks` wide. `PoolKey` requires currency0 < currency1, and
    /// frxUSD (0x0000…f1E5) sorts below USDG (0x5fc5…d168), so frxUSD is always currency0 for this pair: the other token
    /// order is the other swap direction, which `PUSHES` covers on both sides of the band.
    function _sources(uint24 rangeTicks) internal {
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        factory = IGageRehypoSourceFactoryNext(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(manager), address(registry), address(0)))
        );
        IGageRehypoSourceFactoryFailsafe f = IGageRehypoSourceFactoryFailsafe(address(factory));
        vm.startPrank(partner);
        frxSource = IGageRehypoSourceNext(
            f.create(IERC20(FRXUSD), address(0), partner, partner, 10_000, _settings(rangeTicks), failsafeBps, "frx")
        );
        usdgSource = IGageRehypoSourceNext(
            f.create(
                IERC20(USDG), address(usdgVault), partner, partner, 2000, _settings(rangeTicks), failsafeBps, "usdg"
            )
        );
        vm.stopPrank();
        assertEq(usdgSource.RANGE_TICKS(), rangeTicks);
    }

    /// @dev The pool on `at`, both sources bound and keepered, every holder funded, the seed in and the keeper's first
    /// pass made.
    function _pool(uint24 fee_, address at) internal {
        fee = fee_;
        hook = ReHypothecationERC4626Mock(payable(at));
        poolKey = PoolKey(Currency.wrap(FRXUSD), Currency.wrap(USDG), fee_, int24(1), IHooks(at));
        manager.initialize(poolKey, PAR);

        vm.startPrank(partner);
        frxSource.bind(poolKey);
        usdgSource.bind(poolKey);
        usdgSource.setKeeper(keeper, true);
        frxSource.setKeeper(keeper, true);
        vm.stopPrank();

        address[3] memory holders = [partner, trader, lp];
        for (uint256 i; i < holders.length; ++i) {
            deal(FRXUSD, holders[i], 1_000_000e18);
            deal(USDG, holders[i], 1_000_000e6);
            vm.startPrank(holders[i]);
            IERC20(FRXUSD).approve(at, type(uint256).max);
            IERC20(USDG).approve(at, type(uint256).max);
            IERC20(FRXUSD).approve(address(router), type(uint256).max);
            IERC20(USDG).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        deal(USDG, address(manager), IERC20(USDG).balanceOf(address(manager)) + 1_000_000e6);
        deal(FRXUSD, address(manager), IERC20(FRXUSD).balanceOf(address(manager)) + 1_000_000e18);

        vm.prank(partner);
        hook.seedLiquidity(SEED_FRX, SEED_USDG);
        (uint160 lo, uint160 hi) = KitBands.around(PAR);
        vm.startPrank(keeper);
        usdgSource.rebalance(lo, hi);
        frxSource.rebalance(lo, hi);
        vm.stopPrank();
    }

    /// @dev One pool and its two sources at `fee`, declared `rangeTicks` wide, on OpenZeppelin's hook with the range
    /// `follows`/`half` around `centre` (half `type(int24).max` for the full range).
    function _stack(uint24 fee_, uint160 hookSalt, uint24 rangeTicks, bool follows, int24 half, int24 centre) internal {
        _sources(rangeTicks);
        address at = address(FLAGS | (hookSalt << 144));
        assertEq(at.code.length, 0, "no contract at the hook's address");
        deployCodeTo(
            "RangedReHypothecationMocks.sol:RangedReHypothecationMock",
            abi.encode(address(manager), address(frxSource), address(usdgSource), follows, half, centre),
            at
        );
        _pool(fee_, at);
    }

    function _stack(uint24 fee_, uint160 hookSalt, uint24 rangeTicks, bool follows, int24 half) internal {
        _stack(fee_, hookSalt, rangeTicks, follows, half, int24(-276_324));
    }

    /// @dev The same with the per-range ledger hook: several ranges added in one swap. `split` is how the ledger nets
    /// the float across them (1: each range sized from the full `maxWithdraw`; n: each at 1/n of it).
    function _stackMulti(
        uint24 fee_,
        uint160 hookSalt,
        uint24 rangeTicks,
        int24[] memory los,
        int24[] memory his,
        uint256 split
    ) internal {
        _sources(rangeTicks);
        address at = address(FLAGS | (hookSalt << 144));
        assertEq(at.code.length, 0, "no contract at the hook's address");
        deployCodeTo(
            "RangedReHypothecationMocks.sol:MultiRangeReHypothecationMock",
            abi.encode(address(manager), address(frxSource), address(usdgSource), los, his, split),
            at
        );
        _pool(fee_, at);
    }

    // ---------------------------------------------------------------- reads

    function _band() internal view returns (uint160 lo, uint160 hi) {
        return (bandLo, bandHi);
    }

    function _sqrtPriceAt(uint256 bps) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(bps * 1e6, 1 << 192, 10_000 * 1e18)));
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
    }

    function _target() internal view returns (uint256) {
        return Math.mulDiv(usdgSource.totalAssets(), usdgSource.floatBps(), 10_000);
    }

    function _pastBandDepth(uint256 target) internal view returns (uint256) {
        return Math.mulDiv(target, usdgSource.PAST_BAND_BPS(), 10_000);
    }

    /// @dev The source's past-band cap written out: 1% of the target times (s)^4, each step rounded down, then scaled
    /// by the declared range's concentration.
    function _capAt(uint256 target, uint160 price, uint160 lo, uint160 hi) internal view returns (uint256 cap) {
        cap = _pastBandDepth(target);
        (uint256 num, uint256 den) = price < lo ? (uint256(price), uint256(lo)) : (uint256(hi), uint256(price));
        for (uint256 i; i < 4; ++i) {
            cap = Math.mulDiv(cap, num, den);
        }
        uint256 range = usdgSource.RANGE_TICKS();
        if (range != 0) cap = Math.mulDiv(cap, range, range + usdgSource.CONCENTRATION_TICKS());
    }

    /// @dev The source's in-band cap written out (`_inBandCap`, the third generation): the band's width as the source
    /// counts it and the declared range, the smaller of the target, a round's bound and a stretch's; the target for the
    /// full range.
    function _inBandCapAt(uint256 target, uint160 lo, uint160 hi) internal view returns (uint256) {
        uint256 r = usdgSource.RANGE_TICKS();
        if (r == 0) return target;
        uint256 w = Math.mulDiv(hi - lo, 20_001, lo) + 1;
        uint256 rc = r * usdgSource.CONCENTRATION_TICKS();
        uint256 rPlusC = r + usdgSource.CONCENTRATION_TICKS();
        uint256 bps = usdgSource.PAST_BAND_BPS();
        uint256 round =
            rc > w * rPlusC ? Math.mulDiv(target, bps * rc, 16 * w * w * rPlusC) : Math.mulDiv(target, bps, 16 * w);
        uint256 stretch = Math.mulDiv(target, bps * rc, 5 * w * w * rPlusC);
        return Math.min(target, Math.min(round, stretch));
    }

    function _claims(address who, address token) internal view returns (uint256) {
        return manager.balanceOf(who, uint256(uint160(token)));
    }

    /// @dev Tokens plus the PoolManager's ERC-6909 claims, at par: the value an account actually holds.
    function _atPar(address who) internal view returns (int256) {
        return int256(
            IERC20(FRXUSD).balanceOf(who) / 1e12 + IERC20(USDG).balanceOf(who) + _claims(who, FRXUSD) / 1e12
                + _claims(who, USDG)
        );
    }

    function _systemValue() internal view returns (int256 v) {
        address[9] memory all = [
            trader,
            partner,
            lp,
            keeper,
            vaultDepositor,
            address(hook),
            address(frxSource),
            address(usdgSource),
            address(usdgVault)
        ];
        // Every external holder's tokens plus claims. The manager is left out: its token balance backs the claims, so
        // counting it alongside them would count the float twice.
        for (uint256 i; i < all.length; ++i) {
            v += _atPar(all[i]);
        }
    }

    /// @dev Everything the float-only frxUSD source holds, in raw frxUSD.
    function _frxHeld() internal view returns (uint256) {
        return IERC20(FRXUSD).balanceOf(address(frxSource)) + _claims(address(frxSource), FRXUSD);
    }

    // ---------------------------------------------------------------- moves

    function _swapTo(address who, bool zeroForOne, uint160 limit) internal {
        vm.prank(who, who);
        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(500_000e18) : -int256(500_000e6),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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

    /// @dev The pusher's setup, as in a review: another vault depositor takes the vault's free cash, the
    /// LPs leave until the USDG float is a sliver (`kept` hundredths of a percent of the hook's shares stay), the trader
    /// pushes the price to `pushed`, the last LPs that can leave do, and the vault depositor puts its cash back.
    function _pushOnASliver(uint160 pushed, uint256 kept) internal returns (int256 push) {
        deal(USDG, vaultDepositor, 20_000e6);
        vm.startPrank(vaultDepositor);
        IERC20(USDG).approve(address(usdgVault), type(uint256).max);
        usdgVault.deposit(20_000e6, vaultDepositor);
        vm.stopPrank();
        usdgVault.lend(80_000e6);

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
        assertEq(usdgSource.swapFloat(), 0, "the USDG float is gone");
    }

    /// @dev The keeper's pass over both sides (2.1: the float-only side too).
    function _rebalanceBoth() internal returns (uint256 usdgDepth, uint256 frxDepth) {
        (uint160 lo, uint160 hi) = _band();
        vm.startPrank(keeper);
        usdgSource.rebalance(lo, hi);
        frxSource.rebalance(lo, hi);
        vm.stopPrank();
        usdgDepth = usdgSource.swapFloat();
        frxDepth = frxSource.swapFloat();
    }

    /// @dev The trade back to parity. Far past the band a narrow source's reopen can round to nothing on the leg a
    /// two-sided range needs, and OpenZeppelin's hook then refuses the swap (`NoUsableLiquidity`): the 29 October
    /// freeze far out, counted in `frozen`, never a leak.
    function _tradeBack() internal returns (int256 back) {
        int256 start = _atPar(trader);
        try this.swapTo(_price() > PAR, PAR) {
            assertEq(_price(), PAR, "traded back to one for one");
        } catch {
            ++frozen;
        }
        back = _atPar(trader) - start;
    }

    /// @dev One swap of the trader's, external so a refused swap can be caught.
    function swapTo(bool zeroForOne, uint160 limit) external {
        require(msg.sender == address(this), "self only");
        _swapTo(trader, zeroForOne, limit);
    }

    // ---------------------------------------------------------------- rounds and stretches

    function _round(uint256 bps, uint160 pushed, uint256 kept) internal returns (int256 net, uint256 reopened) {
        int256 before = _systemValue();
        int256 push = _pushOnASliver(pushed, kept);
        uint256 target = _target();
        (reopened,) = _rebalanceBoth();
        (uint160 lo, uint160 hi) = _band();
        if (pushed >= lo && pushed <= hi) {
            assertEq(
                reopened,
                Math.min(_inBandCapAt(target, lo, hi), usdgSource.float()),
                "inside the band swaps open to the declared range's cap"
            );
        } else {
            uint256 cap = _capAt(target, pushed, lo, hi);
            assertEq(reopened, Math.min(cap, usdgSource.float()), "past the band, swaps open to the scaled cap");
        }
        int256 held = _systemValue();
        int256 back = _tradeBack();
        net = push + back;
        console2.log(
            string.concat(
                "  round bps=",
                vm.toString(bps),
                " kept=",
                vm.toString(kept),
                " push=",
                vm.toString(push),
                " back=",
                vm.toString(back),
                " net=",
                vm.toString(net),
                " sysLoss=",
                vm.toString(held - _systemValue())
            )
        );
        // `_pushOnASliver` funds a 20,000 USDG deposit into the stand-in vault each round: that mint is the only value
        // entering, so the round closes if and only if the system is 20,000 USDG richer and the trader is inside the sum.
        assertApproxEqAbs(_systemValue() - 20_000e6, before, 1e5, "value moves between these accounts and nowhere else");
    }

    function _worstRound(uint256 bps) internal returns (int256 worst) {
        worst = type(int256).min;
        for (uint256 i; i < FLOATS.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            (int256 net,) = _round(bps, _sqrtPriceAt(bps), FLOATS[i]);
            if (net > worst) worst = net;
            vm.revertToStateAndDelete(snapshot);
        }
    }

    /// @dev A push far below the band, then the trade back in steps between the keeper's passes, each step doubling
    /// the sqrt price, until the price is back in the band.
    function _stretch(uint256 bps) internal returns (int256 net) {
        int256 before = _systemValue();
        net = _pushOnASliver(_sqrtPriceAt(bps), 100);
        for (uint256 pass; pass < 40 && _price() < BAND_LO; ++pass) {
            _rebalanceBoth();
            int256 start = _atPar(trader);
            uint160 step = uint160(Math.min(uint256(_price()) * 2, PAR));
            try this.swapTo(false, step) {}
            catch {
                // Past the band a narrow source's reopen can round to nothing: OpenZeppelin's hook then refuses the
                // swap (`NoUsableLiquidity`), the documented freeze far out, not a leak.
                ++frozen;
                break;
            }
            net += _atPar(trader) - start;
        }
        assertApproxEqAbs(
            _systemValue() - 20_000e6, before, 1e5, "a stretch leaks nothing beyond the stand-in's rounding"
        );
    }

    /// @dev The worst round over every push and float, in basis points of the edge depth.
    function _roundBound(string memory label) internal returns (int256 worstBps) {
        uint256 edge = _pastBandDepth(_target());
        worstBps = type(int256).min;
        for (uint256 i; i < PUSHES.length; ++i) {
            int256 bps = _worstRound(PUSHES[i]) * 10_000 / int256(edge);
            console2.log(string.concat(label, " push ", vm.toString(PUSHES[i]), " netBps ", vm.toString(bps)));
            if (bps > worstBps) worstBps = bps;
        }
        console2.log(string.concat(label, " WORST ROUND bps ", vm.toString(worstBps), " frozen ", vm.toString(frozen)));
    }

    /// @dev The worst stretch over `FROM`, in basis points of the edge depth.
    function _stretchBound(string memory label) internal returns (int256 worstBps) {
        uint256 edge = _pastBandDepth(_target());
        worstBps = type(int256).min;
        for (uint256 i; i < FROM.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            int256 bps = _stretch(FROM[i]) * 10_000 / int256(edge);
            vm.revertToStateAndDelete(snapshot);
            console2.log(string.concat(label, " stepwise ", vm.toString(FROM[i]), " netBps ", vm.toString(bps)));
            if (bps > worstBps) worstBps = bps;
        }
        console2.log(string.concat(label, " WORST STRETCH bps ", vm.toString(worstBps)));
    }

    /// @dev The pass bar on the shape the stack carries.
    function _passes(string memory label) internal {
        assertLe(_roundBound(label), ROUND_BAR, "under a fifteenth of the edge depth per round");
        assertLe(_stretchBound(label), STRETCH_BAR, "under a quarter of the edge depth per stretch");
    }

    uint256[12] internal PUSHES =
        [uint256(9980), 9940, 9500, 8000, 5000, 2500, 100, 20, 10_060, 10_500, 12_000, 20_000];
    uint256[3] internal FROM = [uint256(8000), 5000, 100];
    /// @dev The float left for the push, in hundredths of a percent of the hook's shares: about 200, 20 and 1 USDG of
    /// a 100k seed, the brief's thin floats.
    uint256[3] internal FLOATS = [uint256(200), 20, 1];

    // ---------------------------------------------------------------- the bound: full range, as today

    /// @dev A full-range source with full-range JIT: the numbers stay where they were before the new generation.
    function test_fork_bound_fullRangeOnAFullRangeSource() public {
        _stack(100, 0x7001, 0, false, type(int24).max);
        _passes("full on full     ");
    }

    function test_fork_bound_fullRangeOnAFullRangeSource_dynamicFee() public {
        _stack(0x800000, 0x7101, 0, false, type(int24).max);
        _passes("full on full dyn ");
    }

    // ---------------------------------------------------------------- the bound: every shape at the floor

    /// @dev Every shape at least `FLOOR` ticks wide, on sources declared `FLOOR` wide: the narrowest declaration passes
    /// for each, static and dynamic fees.
    function test_fork_bound_fullRangeOnTheFloor() public {
        _stack(100, 0x7201, FLOOR, false, type(int24).max);
        _passes("full on 100      ");
    }

    function test_fork_bound_fixedPoint5OnTheFloor() public {
        _stack(100, 0x7203, FLOOR, false, 50);
        _passes("fixed+-0.5 on 100 ");
    }

    function test_fork_bound_followsPoint5OnTheFloor() public {
        _stack(100, 0x7205, FLOOR, true, 50);
        _passes("f+-0.5 on 100    ");
    }

    function test_fork_bound_followsFiveOnTheFloor() public {
        _stack(100, 0x7206, FLOOR, true, 500);
        _passes("f+-5 on 100      ");
    }

    function test_fork_bound_fixedPoint5OnTheFloor_dynamicFee() public {
        _stack(0x800000, 0x7303, FLOOR, false, 50);
        _passes("fixed+-0.5 on 100 dyn");
    }

    function test_fork_bound_followsPoint5OnTheFloor_dynamicFee() public {
        _stack(0x800000, 0x7305, FLOOR, true, 50);
        _passes("f+-0.5 on 100 dyn ");
    }

    /// @dev The 8 November worst shape: one fixed range whose lower edge sits on the pushed tick, where the first
    /// generation paid the pusher the uncapped frxUSD float (over 4,400 USDG of a 200 USDG edge).
    function test_fork_bound_rangeEdgeAtPushedTickOnTheFloor() public {
        _stack(100, 0x7209, FLOOR, false, 2232, int24(-276_324));
        _passes("edge@push on 100 ");
    }

    /// @dev The fuzz sweep's worst fixed range that does not contain the pushed tick: about +-0.9% centred just below
    /// parity.
    function test_fork_bound_fuzzFoundShapeOnTheFloor() public {
        _stack(100, 0x720a, FLOOR, false, 901, int24(-276_494));
        _passes("fuzz shape on 100 ");
    }

    /// @dev A per-range ledger adding two ranges in one swap, netted, the outer one with its edge on the pushed tick.
    function test_fork_bound_outerRangeAtPushedTickOnTheFloor() public {
        int24[] memory los = new int24[](2);
        int24[] memory his = new int24[](2);
        (los[0], his[0]) = (int24(-276_374), int24(-276_274));
        (los[1], his[1]) = (int24(-278_556), int24(-274_092));
        _stackMulti(100, 0x720c, FLOOR, los, his, 2);
        _passes("outer@push on 100 ");
    }

    // ---------------------------------------------------------------- the bound: each shape at its own width

    function test_fork_bound_followsFiveAtItsWidth() public {
        _stack(100, 0x7406, 1000, true, 500);
        _passes("f+-5 on 1000     ");
    }

    function test_fork_bound_rangeEdgeAtPushedTickAtItsWidth() public {
        _stack(100, 0x7409, 4464, false, 2232, int24(-276_324));
        _passes("edge@push on 4464");
    }

    /// @dev Range width and centre as fuzz inputs, every shape at least `FLOOR` wide on sources declared `FLOOR` wide,
    /// at one push twenty percent below parity: under a fifteenth of the edge, and nothing minted.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_fork_rangeWidthAndCentreOnTheFloor(int24 half, int24 offset) public {
        half = int24(bound(half, int24(FLOOR / 2), 2000));
        offset = int24(bound(offset, -2000, 2000));
        int24 centre = int24(-276_324) + offset;
        _stack(100, 0x7509, FLOOR, false, half, centre);
        uint160 pushed = _sqrtPriceAt(8000);
        uint256 edge = _pastBandDepth(_target());
        int256 before = _systemValue();
        (int256 net,) = _round(8000, pushed, 1);
        console2.log(
            string.concat(
                "fuzz half=",
                vm.toString(half),
                " centre=",
                vm.toString(centre),
                " netBps=",
                vm.toString(net * 10_000 / int256(edge))
            )
        );
        assertLe(net * 10_000 / int256(edge), ROUND_BAR, "every shape at the floor stays under a fifteenth");
        assertApproxEqAbs(_systemValue() - 20_000e6, before, 1e5, "the fuzzed round mints nothing");
    }

    // ---------------------------------------------------------------- the declaration is what holds the bound

    /// @dev A hook narrower than its source's declaration, pushed inside the band: the second generation reopened swaps
    /// in full there, and a +-0.1% range concentrated that reopen past a fifteenth of the edge depth. The third
    /// generation's in-band cap (`_inBandCap`) holds it under. The declaration still sets that cap and, past the band,
    /// the scaled one: a hook stays at least as wide as it declares (checklist item 6).
    function test_fork_inBandCap_fixedPoint1NarrowerThanItsDeclaration() public {
        _stack(100, 0x7602, FLOOR, false, 10);
        uint256 edge = _pastBandDepth(_target());
        int256 bps = _worstRound(9980) * 10_000 / int256(edge);
        console2.log(string.concat("fixed+-0.1 on 100, push 9980 inside the band: netBps ", vm.toString(bps)));
        assertLe(bps, ROUND_BAR, "inside the band the in-band cap holds a range narrower than declared");
    }

    function test_fork_inBandCap_followsPoint1NarrowerThanItsDeclaration() public {
        _stack(100, 0x7604, FLOOR, true, 10);
        uint256 edge = _pastBandDepth(_target());
        int256 bps = _worstRound(9980) * 10_000 / int256(edge);
        console2.log(string.concat("f+-0.1 on 100, push 9980 inside the band: netBps ", vm.toString(bps)));
        assertLe(bps, ROUND_BAR, "inside the band the in-band cap holds a range narrower than declared");
    }

    /// @dev A narrow hook on a source declared full range still breaches, as on the first generation: a full-range
    /// source's partner must add JIT across the full range (checklist item 6).
    function test_fork_breach_fixedPoint5OnAFullRangeSource() public {
        _stack(100, 0x7603, 0, false, 50);
        assertGt(_roundBound("fixed+-0.5 on full"), ROUND_BAR, "over a fifteenth: the declaration was false");
    }

    function test_fork_breach_rangeEdgeAtPushedTickOnAFullRangeSource() public {
        _stack(100, 0x7609, 0, false, 2232, int24(-276_324));
        (int256 net,) = _round(8000, _sqrtPriceAt(8000), 1);
        int256 bps = net * 10_000 / int256(_pastBandDepth(_target()));
        console2.log(string.concat("edge@push on full: netBps ", vm.toString(bps)));
        assertGt(bps, 100_000, "the first generation's worst case, unchanged on a full-range declaration");
    }

    /// @dev Negative control: with the band widened to the pushed price the rebalance opens the full float, and the
    /// pusher gains on a narrow declaration too. This proves the harness can see the leak.
    function test_fork_negativeControl_bandWidenedOnTheFloor() public {
        _stack(100, 0x7703, FLOOR, false, 50);
        uint160 pushed = _sqrtPriceAt(8000);
        (bandLo, bandHi) = (pushed, pushed);
        (int256 net,) = _round(8000, pushed, 1);
        console2.log(string.concat("NEGATIVE CONTROL fixed+-0.5 on 100, band widened: net ", vm.toString(net)));
        assertGt(net, 0, "a widened band hands the pusher the whole re-opened float");
    }

    // ---------------------------------------------------------------- who pays, and both sides capped

    /// @dev Who pays for the trade back on a narrow declaration: each source's loss stays inside the swap float its
    /// keeper re-opened, the float-only frxUSD side included (2.1).
    function _attribute(string memory label, uint256 bps) internal {
        _pushOnASliver(_sqrtPriceAt(bps), 1);
        (uint256 usdgReopened, uint256 frxReopened) = _rebalanceBoth();
        int256 frxBefore = _atPar(address(frxSource));
        int256 usdgBefore = _atPar(address(usdgSource));
        int256 back = _tradeBack();
        int256 frxLoss = frxBefore - _atPar(address(frxSource));
        int256 usdgLoss = usdgBefore - _atPar(address(usdgSource));
        console2.log(
            string.concat(
                label,
                " bps=",
                vm.toString(bps),
                " back=",
                vm.toString(back),
                " frxLoss=",
                vm.toString(frxLoss),
                " usdgLoss=",
                vm.toString(usdgLoss),
                " frxReopened=",
                vm.toString(frxReopened / 1e12),
                " usdgReopened=",
                vm.toString(usdgReopened)
            )
        );
        assertApproxEqAbs(frxLoss + usdgLoss, back, 1e3, "the trade back pays the trader out of the two sources alone");
        assertLe(frxLoss, int256(frxReopened / 1e12) + 1, "the frxUSD side pays at most what its keeper re-opened");
        assertLe(usdgLoss, int256(usdgReopened), "the USDG side pays at most what its keeper re-opened");
    }

    function test_fork_attribution_fixedPoint5OnTheFloor() public {
        _stack(100, 0x7803, FLOOR, false, 50);
        _attribute("attr fixed+-0.5 on 100", 9940);
    }

    function test_fork_attribution_rangeEdgeAtPushedTickOnTheFloor() public {
        _stack(100, 0x7809, FLOOR, false, 2232, int24(-276_324));
        _attribute("attr edge@push on 100", 8000);
    }

    /// @dev The float-only frxUSD side is capped past the band on a narrow declaration (2.1 with 2.2): a concentrated
    /// round takes at most the scaled cap of it, where the first generation let it take the float.
    function test_fork_frxSide_cappedOnTheFloor() public {
        _stack(100, 0x7903, FLOOR, false, 50);
        int256 before = _systemValue();
        _pushOnASliver(_sqrtPriceAt(9940), 1);
        uint256 afterPush = _frxHeld();
        uint256 frxTarget = Math.mulDiv(frxSource.totalAssets(), frxSource.floatBps(), 10_000);
        (, uint256 frxReopened) = _rebalanceBoth();
        (uint160 lo, uint160 hi) = _band();
        uint256 frxCap = Math.mulDiv(frxTarget, 100, 10_000);
        (uint256 num, uint256 den) =
            _sqrtPriceAt(9940) < lo ? (uint256(_sqrtPriceAt(9940)), uint256(lo)) : (uint256(hi), uint256(_price()));
        for (uint256 i; i < 4; ++i) {
            frxCap = Math.mulDiv(frxCap, num, den);
        }
        frxCap = Math.mulDiv(frxCap, FLOOR, FLOOR + 40_003);
        assertEq(frxReopened, Math.min(frxCap, frxSource.float()), "the frxUSD side is held to the scaled cap");
        _tradeBack();
        uint256 taken = afterPush - _frxHeld();
        console2.log(
            string.concat(
                "frx side on 100: afterPush=",
                vm.toString(afterPush),
                " taken=",
                vm.toString(taken),
                " reopened=",
                vm.toString(frxReopened)
            )
        );
        assertLe(taken, frxReopened, "a concentrated round takes no more than the scaled cap");
        assertApproxEqAbs(_systemValue() - 20_000e6, before, 1e5, "the round moves value and mints nothing");
    }

    // ---------------------------------------------------------------- liveness and containment

    /// @dev One concentrated round on a narrow declaration, checked for the four things the source promises whoever
    /// the hook is: swaps run without the vault, LP exits stay open, swaps cannot be frozen by the source, and the round
    /// moves no more than the floats.
    function test_fork_containment_fixedPoint5OnTheFloor() public {
        _containment(0x7a03, false, 50);
    }

    function test_fork_containment_followsPoint5OnTheFloor() public {
        _containment(0x7a05, true, 50);
    }

    function _containment(uint160 hookSalt, bool follows, int24 half) internal {
        _stack(100, hookSalt, FLOOR, follows, half);
        uint160 pushed = _sqrtPriceAt(9940);
        int256 before = _systemValue();

        _swapTo(trader, true, pushed);
        (uint256 reopened,) = _rebalanceBoth();
        assertLe(reopened, _target(), "past the band the USDG float opens at most to the target");

        // No swap touches the lending vault: with it offline, every view and call to it reverts.
        usdgVault.setOffline(true);
        uint256 callsBefore = usdgVault.calls();
        if (follows) {
            // A range centred on the price is two sided and needs both legs; past the band both are held to the
            // scaled cap, so the trade back runs on slivers.
            try this.swapTo(false, PAR) {} catch {}
        } else {
            _tradeBack();
        }
        assertEq(usdgVault.calls(), callsBefore, "no swap called the vault");

        // An LP can still leave, at the pushed price and after it, and back inside the band swaps open in full.
        usdgVault.setOffline(false);
        uint256 partnerShares = hook.balanceOf(partner) / 2;
        int256 partnerBefore = _atPar(partner);
        _exit(partnerShares);
        assertGt(_atPar(partner), partnerBefore, "an LP exit pays out");
        if (_price() != PAR) {
            // Traders bring the price back over the thin past-band floats; the source never stops them.
            try this.swapTo(false, PAR) {} catch {}
        }
        console2.log(
            string.concat("containment: systemBefore=", vm.toString(before), " now=", vm.toString(_systemValue()))
        );
        assertApproxEqAbs(_systemValue(), before, 1e5, "the round moves value between these accounts and nowhere else");
    }

    // ---------------------------------------------------------------- the vault failsafe (2.5): off and on

    /// @dev With the failsafe on (10% of the backing) and OpenZeppelin's hooks, which never ask for it, every round and
    /// stretch nets exactly what it does with the failsafe off, full range and at the floor.
    function test_fork_failsafeOnLeavesEveryRoundUnchanged() public {
        uint256 snapshot = vm.snapshotState();
        _stack(100, 0x7c01, 0, false, type(int24).max);
        int256 fullOff = _roundBound("full, failsafe off ");
        int256 fullStretchOff = _stretchBound("full, failsafe off ");
        vm.revertToStateAndDelete(snapshot);
        snapshot = vm.snapshotState();
        _stack(100, 0x7c02, FLOOR, false, 50);
        int256 narrowOff = _roundBound("+-0.5 on 100, failsafe off ");
        vm.revertToStateAndDelete(snapshot);

        failsafeBps = 1000;
        snapshot = vm.snapshotState();
        _stack(100, 0x7c03, 0, false, type(int24).max);
        assertEq(_roundBound("full, failsafe on  "), fullOff, "full range: the same rounds");
        assertEq(_stretchBound("full, failsafe on  "), fullStretchOff, "and the same stretches");
        vm.revertToStateAndDelete(snapshot);
        _stack(100, 0x7c04, FLOOR, false, 50);
        assertEq(_roundBound("+-0.5 on 100, failsafe on  "), narrowOff, "at the floor: the same rounds");
    }

    // ---------------------------------------------------------------- the watch: depth past the band

    /// @dev What a narrow declaration leaves past the band (design 2.2, "Watch"): the USDG swap float a pass opens at
    /// each distance below the band, for declarations of 0, 100, 400 and 1,000 ticks, and where it rounds to zero raw
    /// (the 29 October total freeze far out). Report only; the pass bar is above.
    function test_fork_depthPastTheBand() public {
        uint24[4] memory widths = [uint24(0), FLOOR, 400, 1000];
        uint256[7] memory at = [uint256(9940), 9500, 8000, 5000, 2000, 100, 10];
        for (uint256 w; w < widths.length; ++w) {
            uint256 snapshot = vm.snapshotState();
            _stack(100, uint160(0x7b00 + w), widths[w], false, type(int24).max);
            uint256 target = _target();
            string memory line = string.concat("depth on ", vm.toString(widths[w]), " (target ", vm.toString(target));
            line = string.concat(line, "):");
            for (uint256 i; i < at.length; ++i) {
                uint256 cap = _capAt(target, _sqrtPriceAt(at[i]), BAND_LO, BAND_HI);
                line = string.concat(line, " ", vm.toString(at[i]), "bps=", vm.toString(cap));
            }
            // The farthest push, in hundredths of a basis point of parity, that still reopens one raw unit.
            uint256 lo = 1;
            uint256 hi = 994_000;
            while (lo < hi) {
                uint256 mid = (lo + hi) / 2;
                uint160 p = uint160(Math.sqrt(Math.mulDiv(mid * 1e6, 1 << 192, 1_000_000 * 1e18)));
                if (_capAt(target, p, BAND_LO, BAND_HI) == 0) lo = mid + 1;
                else hi = mid;
            }
            console2.log(string.concat(line, " | reopens nothing below ", vm.toString(lo), " millionths of parity"));
            vm.revertToStateAndDelete(snapshot);
        }
    }
}
