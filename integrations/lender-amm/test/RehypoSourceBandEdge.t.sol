// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {AnchoredUnlockCheckedHook} from "../src/AnchoredUnlockCheckedHook.sol";
// Deployed by name (`deployCodeTo`).
import {RangedUnlockCheckedHook} from "./mocks/RangedUnlockCheckedHooks.sol";
import {FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {RehypoSourceSettings} from "../script/RehypoSource.s.sol";
import {KitBands} from "./utils/KitBands.sol";

interface IBandEdgeFactory {
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external returns (address);
}

interface IBandEdgeSource {
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function rebalance(uint160 lo, uint160 hi) external;
    function totalAssets() external view returns (uint256);
    function swapFloat() external view returns (uint256);
    function floatBps() external view returns (uint16);
}

/// @notice Tight and wide ranges at the band's edge (design 2.2): a frxUSD/USDG pool on the kit's anchored reference
/// hook (`AnchoredUnlockCheckedHook`: its just-in-time range fixed on parity, sized there), frxUSD float-only and USDG lent
/// through a gage vault, both sources declared at the hook's width. A trader pushes the price anywhere inside the
/// keeper's +-0.5% band, up to its edge; the keeper's pass follows; the trader trades back to parity, in one swap or in
/// twenty. What the trader gains is what the LPs lose (asserted), and it stays under a sixteenth of the edge depth (1% of
/// the float target) of the side the trade back takes; a trade back in steps over several keeper passes, under a quarter.
/// Both with the kit's float-only side at 100% and with balanced targets. The backstop tests hold the in-band cap alone to
/// the same bounds against a range that follows the price (unsupported, docs/rehypo-source.md item 6), with the fair
/// price at the band's centre and anywhere inside the band. Runs on a fresh PoolManager with stand-in tokens at
/// mainnet's addresses, so the pool's token order is mainnet's.
contract RehypoSourceBandEdgeTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRX = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev 1 frxUSD for 1 USDG in raw units, as a v4 sqrt price.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    /// @dev The bounds, in basis points of the edge depth: a sixteenth per round, a quarter per stretch.
    int256 internal constant ROUND_BAR = 625;
    int256 internal constant STRETCH_BAR = 2500;

    IPoolManager internal pm;
    PoolSwapTest internal router;
    MockGageVault internal vault;
    IBandEdgeSource internal s0; // frxUSD, float-only
    IBandEdgeSource internal s1; // USDG, lent
    PoolKey internal key;
    uint160 internal bandLo;
    uint160 internal bandHi;
    uint160 internal salt = 0xbe00;
    /// @dev The fair price, USDG per frxUSD, 1e18 for parity: what the trader's and the LPs' tokens are worth.
    uint256 internal fair = 1e18;

    address internal partner = makeAddr("partner");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");

    struct Shape {
        uint24 declared;
        /// @dev 0 the anchored reference hook; 2 the pool's tick plus and minus `half`, re-centred at every swap.
        uint8 mode;
        int24 half;
        string label;
    }

    function setUp() public {
        pm = new PoolManager(address(this));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), USDG);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), FRX);
        router = new PoolSwapTest(pm);
        (bandLo, bandHi) = KitBands.around(PAR);
    }

    // ---------------------------------------------------------------- the stack

    function _build(Shape memory sh, uint16 frxFloatBps) internal {
        _build(sh, frxFloatBps, PAR);
    }

    function _build(Shape memory sh, uint16 frxFloatBps, uint160 initPrice) internal {
        vault = new MockGageVault(IERC20(USDG));
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(vault));
        IBandEdgeFactory f =
            IBandEdgeFactory(deployCode(FACTORY_ARTIFACT, abi.encode(address(pm), address(registry), address(0))));
        RehypoSourceSettings memory st;
        st.rangeTicks = sh.declared;
        vm.startPrank(partner);
        s0 = IBandEdgeSource(f.create(IERC20(FRX), address(0), partner, partner, frxFloatBps, st, "frx"));
        s1 = IBandEdgeSource(f.create(IERC20(USDG), address(vault), partner, partner, 2000, st, "usdg"));
        vm.stopPrank();
        address hook = address(FLAGS | (uint160(++salt) << 144));
        if (sh.mode == 0) {
            deployCodeTo(
                "AnchoredUnlockCheckedHook.sol:AnchoredUnlockCheckedHook",
                abi.encode(address(pm), address(s0), address(s1)),
                hook
            );
        } else {
            deployCodeTo(
                "RangedUnlockCheckedHooks.sol:RangedUnlockCheckedHook",
                abi.encode(address(pm), address(s0), address(s1), sh.mode, int24(0), int24(0), sh.half),
                hook
            );
        }
        key = PoolKey(Currency.wrap(FRX), Currency.wrap(USDG), 100, int24(1), IHooks(hook));
        pm.initialize(key, initPrice);
        vm.startPrank(partner);
        s0.bind(key);
        s1.bind(key);
        s0.setKeeper(keeper, true);
        s1.setKeeper(keeper, true);
        vm.stopPrank();
        address[2] memory who = [partner, trader];
        for (uint256 i; i < 2; ++i) {
            deal(FRX, who[i], 100_000_000e18);
            deal(USDG, who[i], 100_000_000e6);
            vm.startPrank(who[i]);
            IERC20(FRX).approve(hook, type(uint256).max);
            IERC20(USDG).approve(hook, type(uint256).max);
            IERC20(FRX).approve(address(router), type(uint256).max);
            IERC20(USDG).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        // The hook's after-swap takes a swap's input before the swapper pays: a live PoolManager holds that much from its
        // other pools.
        deal(FRX, address(pm), 50_000_000e18);
        deal(USDG, address(pm), 50_000_000e6);
        vm.prank(partner);
        RangedUnlockCheckedHook(payable(hook)).seedLiquidity(100_000e18, 100_000e6);
        _keeper();
    }

    function _keeper() internal {
        vm.startPrank(keeper);
        s1.rebalance(bandLo, bandHi);
        s0.rebalance(bandLo, bandHi);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- reads

    function _price() internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(key.toId());
    }

    /// @dev Value in 1e18 USD, frxUSD at the fair price.
    function _val(uint256 a0, uint256 a1) internal view returns (int256) {
        return int256(Math.mulDiv(a0, fair, 1e18) + a1 * 1e12);
    }

    function _trader() internal view returns (int256) {
        return _val(IERC20(FRX).balanceOf(trader), IERC20(USDG).balanceOf(trader));
    }

    function _lps() internal view returns (int256) {
        address hook = address(key.hooks);
        return _val(s0.totalAssets() + IERC20(FRX).balanceOf(hook), s1.totalAssets() + IERC20(USDG).balanceOf(hook));
    }

    /// @dev A side's edge depth, 1% of its float target, in 1e18 USD at the fair price.
    function _edge0() internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(s0.totalAssets(), s0.floatBps(), 10_000 * 100), fair, 1e18);
    }

    function _edge1() internal view returns (uint256) {
        return Math.mulDiv(s1.totalAssets(), s1.floatBps(), 10_000 * 100) * 1e12;
    }

    function _sqrtAt(uint256 bps) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(bps, 1 << 192, 1e4 * 1e12)));
    }

    // ---------------------------------------------------------------- moves

    function doSwap(bool zeroForOne, uint160 limit) external {
        require(msg.sender == address(this));
        vm.prank(trader, trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(10_000_000e18) : -int256(10_000_000e6),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapTo(uint160 limit) internal {
        uint160 p = _price();
        if (p == limit) return;
        try this.doSwap(limit < p, limit) {} catch {}
    }

    function _stepTo(uint160 limit, uint256 n) internal {
        uint160 p = _price();
        for (uint256 i = 1; i <= n; ++i) {
            uint256 next = limit > p
                ? uint256(p) + (uint256(limit) - uint256(p)) * i / n
                : uint256(p) - (uint256(p) - uint256(limit)) * i / n;
            _swapTo(uint160(next));
        }
    }

    // ---------------------------------------------------------------- rounds

    /// @dev Push to `to`, the keeper's pass, back to `back` in `backSteps` swaps; the gain in basis points of the edge
    /// of the side the trade back takes (frxUSD after a push down, USDG after one up) and of the smaller edge.
    function _round(uint160 to, uint160 back, uint256 backSteps) internal returns (int256 ofTaken, int256 ofSmaller) {
        uint256 snapshot = vm.snapshotState();
        (uint256 e0, uint256 e1) = (_edge0(), _edge1());
        uint256 taken = back > to ? e0 : e1;
        int256 t0 = _trader();
        int256 l0 = _lps();
        _swapTo(to);
        _keeper();
        _stepTo(back, backSteps);
        int256 gain = _trader() - t0;
        assertApproxEqAbs(gain, l0 - _lps(), 5e16, "the trader's gain is the LPs' loss");
        ofTaken = gain * 10_000 / int256(taken);
        ofSmaller = gain * 10_000 / int256(e0 < e1 ? e0 : e1);
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Push to `to`, then `passes` times the keeper's pass and `1 / passes` of the way back to `back` in `k` swaps.
    function _stretch(uint160 to, uint160 back, uint256 passes, uint256 k) internal returns (int256 ofTaken) {
        uint256 snapshot = vm.snapshotState();
        uint256 taken = back > to ? _edge0() : _edge1();
        int256 t0 = _trader();
        int256 l0 = _lps();
        _swapTo(to);
        uint160 from = _price();
        for (uint256 i = 1; i <= passes; ++i) {
            _keeper();
            uint256 next = back > from
                ? uint256(from) + (uint256(back) - uint256(from)) * i / passes
                : uint256(from) - (uint256(from) - uint256(back)) * i / passes;
            _stepTo(uint160(next), k);
        }
        int256 gain = _trader() - t0;
        assertApproxEqAbs(gain, l0 - _lps(), 5e16, "the trader's gain is the LPs' loss");
        ofTaken = gain * 10_000 / int256(taken);
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev The worst of the stretches toward `back` from `to`: eight passes of four swaps, fifty of two, a hundred of one.
    function _worstStretch(uint160 to, uint160 back) internal returns (int256 worst) {
        worst = _stretch(to, back, 8, 4);
        int256 finer = _stretch(to, back, 50, 2);
        if (finer > worst) worst = finer;
        finer = _stretch(to, back, 100, 1);
        if (finer > worst) worst = finer;
    }

    function _grid(Shape memory sh, uint16 frxFloatBps) internal {
        _build(sh, frxFloatBps);
        uint16[13] memory at =
            [9951, 9952, 9955, 9960, 9970, 9980, 9990, 10_010, 10_020, 10_030, 10_040, 10_048, 10_049];
        int256 worst = type(int256).min;
        int256 worstSmaller = type(int256).min;
        for (uint256 i; i < at.length; ++i) {
            for (uint256 steps = 1; steps <= 20; steps += 19) {
                (int256 ofTaken, int256 ofSmaller) = _round(_sqrtAt(at[i]), PAR, steps);
                assertLe(ofTaken, ROUND_BAR, string.concat(sh.label, ": a round past a sixteenth of the edge"));
                if (ofTaken > worst) worst = ofTaken;
                if (ofSmaller > worstSmaller) worstSmaller = ofSmaller;
            }
        }
        int256 stretch = _worstStretch(_sqrtAt(9952), PAR);
        int256 above = _worstStretch(_sqrtAt(10_048), PAR);
        if (above > stretch) stretch = above;
        assertLe(stretch, STRETCH_BAR, string.concat(sh.label, ": a stretch past a quarter of the edge"));
        console2.log(
            string.concat(
                sh.label,
                frxFloatBps == 10_000 ? " (frx 100%)" : " (balanced)",
                " worst round bps of the taken side's edge ",
                vm.toString(worst),
                ", of the smaller edge ",
                vm.toString(worstSmaller),
                "; worst stretch ",
                vm.toString(stretch)
            )
        );
    }

    /// @dev The backstop with the fair price at `fairBps` of parity, inside the band, the pool there: a push to the
    /// band's far edge, the keeper's pass, and the trade back to the fair price, in one round and in stretches.
    function _offCentre(Shape memory sh, uint256 fairBps) internal {
        fair = fairBps * 1e14;
        uint160 fairPrice = _sqrtAt(fairBps);
        _build(sh, 2000, fairPrice);
        uint160 far = _sqrtAt(fairBps < 10_000 ? 10_048 : 9952);
        (int256 one,) = _round(far, fairPrice, 1);
        (int256 twenty,) = _round(far, fairPrice, 20);
        int256 round = one > twenty ? one : twenty;
        int256 stretch = _worstStretch(far, fairPrice);
        assertLe(round, ROUND_BAR, string.concat(sh.label, ": off the centre, a round past a sixteenth of the edge"));
        assertLe(
            stretch, STRETCH_BAR, string.concat(sh.label, ": off the centre, a stretch past a quarter of the edge")
        );
        console2.log(
            string.concat(
                sh.label,
                ", fair at ",
                vm.toString(fairBps),
                " bps of parity: worst round ",
                vm.toString(round),
                ", worst stretch ",
                vm.toString(stretch)
            )
        );
    }

    function _shapes() internal pure returns (Shape[5] memory s) {
        s[0] = Shape(0, 0, 0, "full range");
        s[1] = Shape(100, 0, 0, "+-0.5% anchored");
        s[2] = Shape(20, 0, 0, "+-0.1% anchored");
        s[3] = Shape(10, 0, 0, "+-0.05% anchored");
        s[4] = Shape(2, 0, 0, "+-0.01% anchored");
    }

    /// @dev Ranges re-centred at every swap: not supported, the in-band cap's worst case.
    function _following() internal pure returns (Shape[3] memory s) {
        s[0] = Shape(100, 2, 50, "+-0.5% following the price");
        s[1] = Shape(20, 2, 10, "+-0.1% following the price");
        s[2] = Shape(10, 2, 5, "+-0.05% following the price");
    }

    function test_bandEdge_fullRange_kitLayout() public {
        _grid(_shapes()[0], 10_000);
    }

    function test_bandEdge_fullRange_balancedTargets() public {
        _grid(_shapes()[0], 2000);
    }

    function test_bandEdge_point5_kitLayout() public {
        _grid(_shapes()[1], 10_000);
    }

    function test_bandEdge_point5_balancedTargets() public {
        _grid(_shapes()[1], 2000);
    }

    function test_bandEdge_point1_kitLayout() public {
        _grid(_shapes()[2], 10_000);
    }

    function test_bandEdge_point1_balancedTargets() public {
        _grid(_shapes()[2], 2000);
    }

    function test_bandEdge_point05_kitLayout() public {
        _grid(_shapes()[3], 10_000);
    }

    function test_bandEdge_point05_balancedTargets() public {
        _grid(_shapes()[3], 2000);
    }

    function test_bandEdge_point01_kitLayout() public {
        _grid(_shapes()[4], 10_000);
    }

    function test_bandEdge_point01_balancedTargets() public {
        _grid(_shapes()[4], 2000);
    }

    /// @dev The backstop at the centre: the in-band cap alone holds one round and a stretch on a range that follows
    /// the price.
    function test_backstop_point5Following() public {
        _grid(_following()[0], 2000);
    }

    function test_backstop_point1Following() public {
        _grid(_following()[1], 2000);
    }

    function test_backstop_point05Following() public {
        _grid(_following()[2], 2000);
    }

    /// @dev The backstop off the centre (a fair price anywhere inside the band): the halved stretch term's case.
    function test_backstop_offCentre_point5Following() public {
        _offCentre(_following()[0], 10_048);
        _offCentre(_following()[0], 9952);
    }

    function test_backstop_offCentre_point1Following() public {
        _offCentre(_following()[1], 10_048);
        _offCentre(_following()[1], 9952);
    }

    function test_backstop_offCentre_point05Following() public {
        _offCentre(_following()[2], 10_048);
        _offCentre(_following()[2], 9952);
    }
}
