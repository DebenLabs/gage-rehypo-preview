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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {SignedPriceStandIn} from "./RehypoSourcePricedPlug.t.sol";
import {RehypoSource, RehypoSourceSettings} from "../script/RehypoSource.s.sol";
import {AnchoredUnlockCheckedHook} from "../src/AnchoredUnlockCheckedHook.sol";
import {KitBands} from "./utils/KitBands.sol";
import {FeeModuleStandIn} from "./mocks/FeeModuleStandIn.sol";
// Deployed by name (`deployCodeTo`).
import {RangedUnlockCheckedHook} from "./mocks/RangedUnlockCheckedHooks.sol";

interface IRepeatFactory {
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external returns (address);
    function create(
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external returns (address);
}

interface IRepeatSource {
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function rebalance(uint160 lo, uint160 hi) external;
    function rebalanceAt(bytes calldata report) external;
    function totalAssets() external view returns (uint256);
    function floatBps() external view returns (uint16);
    function swapFloat() external view returns (uint256);
    function swapCap() external view returns (uint256);
    function float() external view returns (uint256);
}

/// @notice The repeat-round property: on the kit's anchored reference hook (`AnchoredUnlockCheckedHook`), a
/// trader pushing the price to the keeper's band edge, alternately below and above, once every keeper pass (five
/// minutes, so 288 rounds a day), each time trading back to the fair price in steps after the keeper's pass reopened
/// swaps, takes the LPs' value under a quarter of the edge depth (1% of the float target) of the smaller side in all, at
/// every round. With the fair price at the anchor: every declared width from the full range to +-0.01%, at 1, 5 and 30
/// bp fees, with the kit's layout (the float-only side at 100%) and balanced targets, on a stable pair and a priced
/// one. With the fair price resting off the anchor anywhere inside the band, either way (a stable pair off parity, a
/// priced pair's venue off the signed price): every declared width with equal float targets on both sides, a declared
/// range's default and a stable pair's rule (docs/rehypo-source.md, item 6), at the same fees; the kit's layout there breaks the bound, its
/// deep side reopened at the anchor every pass. What the trader gains is what the LPs lose (asserted), valued at the
/// fair price. The same rounds break the bound on a range that follows the price, and on the anchored range sized at
/// each swap's price as OpenZeppelin's hook sizes it, which grows deeper toward an edge where one side stops binding
/// (the kit's layout, at the band's width): the property is what tells the shapes apart. Runs on a fresh PoolManager
/// with stand-in tokens at mainnet's addresses (the stable pair) or the priced plug's (NVDA at $180). Every case runs at
/// a 20% and a 10% float target on the lent side (and on the float-only side where targets are equal). A pegged pair
/// (frxUSD/USDG on its signed price, `PEG_BPS`) opens its whole float inside the band and holds the same bound. The kit's
/// fee hook (`AnchoredFeeHook`, on a dynamic-fee pool, `feeHook`) is held to it too, its module quoting each of
/// the same fees, and a different fee each way.
abstract contract RehypoRepeatBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev A day of keeper passes at the keeper's default five-minute interval.
    uint256 internal constant ROUNDS = 288;
    /// @dev The trade back's swaps each round.
    uint256 internal constant BACK_STEPS = 10;
    /// @dev The bound: a quarter of the smaller side's edge depth, in basis points of it.
    int256 internal constant BAR = 2500;
    /// @dev `Run.floatOnlyBps` for equal float targets: the float-only side takes the lent side's.
    uint16 internal constant EQUAL = 0;

    IPoolManager internal pm;
    PoolSwapTest internal router;
    MockGageVault internal vault;
    IRepeatSource internal s0;
    IRepeatSource internal s1;
    PoolKey internal key;
    uint160 internal salt = 0xd490;
    /// @dev The fair price, in basis points of the anchor (parity, or the signed centre): what the rounds trade back to
    /// and value at.
    uint256 internal fairBps = 10_000;
    /// @dev Both sources' failsafe (the lent side draws on its vault's free cash, the float-only side on the float it
    /// keeps closed); non-zero deploys the anchored failsafe hook.
    uint16 internal failsafeBps;
    /// @dev Leave the stack before its first keeper move.
    bool internal noFirstPass;
    /// @dev The lent side's float target.
    uint16 internal lentBps = 2000;
    /// @dev The anchored failsafe hook's draw economics: the least fee a draw earns in each token, and the lending
    /// return it gives up, in pips of the ask. Zero draws whenever the hook's half rule asks.
    uint256 internal drawFee0;
    uint256 internal drawFee1;
    uint24 internal forgonePips;
    /// @dev Deploy the kit's fee hook (`AnchoredFeeHook`, or `AnchoredFailsafeFeeHook` with the failsafe) on a
    /// dynamic-fee pool, where shape 0 otherwise deploys the anchored hook on a static-fee one: its module quotes `Run.fee` for a swap from token0 and `feeBack` (or
    /// `Run.fee` again, while `feeBack` is zero) for one from token1, inside [`feeFloor`, `feeCap`].
    bool internal feeHook;
    uint24 internal feeBack;
    uint24 internal feeFloor = 100;
    uint24 internal feeCap = 50_000;
    FeeModuleStandIn internal feeModule;
    /// @dev The pool the fee hook asks its module about: the venue's own, not this one.
    bytes32 internal constant FEE_POOL = keccak256("the venue's pool for the pair");

    /// @dev The trade back's swaps each round; one makes it a single swap to the fair price, which the anchored failsafe
    /// hook lets ask where a first small step would not.
    uint256 internal backSteps = BACK_STEPS;
    /// @dev A keeper pass before each push too, so the push sizes the position afresh and may ask the failsafe.
    bool internal passBeforePush;
    /// @dev token0 lends too, through a gage vault of its own, where it is otherwise float-only.
    bool internal bothLent;

    address internal partner = makeAddr("partner");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");

    struct Run {
        uint24 declared;
        uint16 floatOnlyBps;
        uint24 fee;
        /// @dev 0 the anchored reference hook; 1 the same range sized at the swap's price, as OpenZeppelin's hook sizes
        /// it; 2 a range `half` ticks either side of the pool's price at every swap.
        uint8 shape;
        int24 half;
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        router = new PoolSwapTest(pm);
    }

    // ---------------------------------------------------------------- the pair

    function _token0() internal view virtual returns (address);
    function _token1() internal view virtual returns (address);
    function _priceSource() internal view virtual returns (address);
    function _settings(uint24 declared) internal view virtual returns (RehypoSourceSettings memory);
    function _seed() internal view virtual returns (uint256 amount0, uint256 amount1);
    /// @dev The pool's price at the band's centre, as a v4 sqrt price.
    function _centre() internal view virtual returns (uint160);
    /// @dev The price a push takes the pool to: the band's lower edge, or its upper, just inside.
    function _edgePrice(bool below) internal view virtual returns (uint160);
    /// @dev The fair price (`fairBps` of the band's centre), as a v4 sqrt price.
    function _fair() internal view virtual returns (uint160);
    function _keeperPass() internal virtual;
    /// @dev Value at the fair price, in token1's units scaled to 18 decimals.
    function _value(uint256 a0, uint256 a1) internal view virtual returns (int256);

    /// @dev Both sources' peg (`PEG_BPS`); zero but on the pegged pair.
    function _peg() internal view virtual returns (uint16) {
        return 0;
    }

    // ---------------------------------------------------------------- the stack

    /// @dev The vault, a factory on a fresh registry, and both sources: token0 float-only at `floatOnlyBps` (or the lent
    /// side's target), token1 lent at `lentBps`. With `bothLent`, token0 has a vault of its own.
    function _sources(Run memory r) internal {
        vault = new MockGageVault(IERC20(_token1()));
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(vault));
        address vault0;
        if (bothLent) {
            vault0 = address(new MockGageVault(IERC20(_token0())));
            registry.record(vault0);
        }
        IRepeatFactory f =
            IRepeatFactory(deployCode(FACTORY_ARTIFACT, abi.encode(address(pm), address(registry), _priceSource())));
        RehypoSourceSettings memory st = _settings(r.declared);
        uint16 floatOnly = r.floatOnlyBps == EQUAL ? lentBps : r.floatOnlyBps;
        vm.startPrank(partner);
        s0 = IRepeatSource(
            f.create(IERC20(_token0()), vault0, partner, partner, floatOnly, st, failsafeBps, _peg(), "0")
        );
        s1 = IRepeatSource(
            f.create(IERC20(_token1()), address(vault), partner, partner, lentBps, st, failsafeBps, _peg(), "1")
        );
        vm.stopPrank();
    }

    /// @dev token0 float-only at `floatOnlyBps` (or the lent side's target), token1 (USDG) lent through a gage vault at
    /// `lentBps`, both declared `declared` wide, on the anchored hook (or the price-following one), seeded and passed by
    /// the keeper once.
    function _build(Run memory r) internal {
        address t0 = _token0();
        address t1 = _token1();
        _sources(r);
        address hook = address(FLAGS | (uint160(++salt) << 144));
        if (r.shape == 0 && feeHook) {
            feeModule = new FeeModuleStandIn();
            feeModule.set(FEE_POOL, r.fee, feeBack == 0 ? r.fee : feeBack);
            deployCodeTo(
                failsafeBps == 0
                    ? "AnchoredFeeHook.sol:AnchoredFeeHook"
                    : "AnchoredFeeHook.sol:AnchoredFailsafeFeeHook",
                failsafeBps == 0
                    ? abi.encode(address(pm), address(s0), address(s1), feeFloor, feeCap, address(feeModule), FEE_POOL)
                    : abi.encode(
                        address(pm),
                        address(s0),
                        address(s1),
                        drawFee0,
                        drawFee1,
                        forgonePips,
                        feeFloor,
                        feeCap,
                        address(feeModule),
                        FEE_POOL
                    ),
                hook
            );
        } else if (r.shape == 0) {
            deployCodeTo(
                failsafeBps == 0
                    ? "AnchoredUnlockCheckedHook.sol:AnchoredUnlockCheckedHook"
                    : "AnchoredUnlockCheckedHook.sol:AnchoredFailsafeUnlockCheckedHook",
                failsafeBps == 0
                    ? abi.encode(address(pm), address(s0), address(s1))
                    : abi.encode(address(pm), address(s0), address(s1), drawFee0, drawFee1, forgonePips),
                hook
            );
        } else {
            int24 c = TickMath.getTickAtSqrtPrice(_centre());
            deployCodeTo(
                "RangedUnlockCheckedHooks.sol:RangedUnlockCheckedHook",
                abi.encode(address(pm), address(s0), address(s1), r.shape, c - r.half, c + r.half, r.half),
                hook
            );
        }
        uint24 keyFee = r.shape == 0 && feeHook ? LPFeeLibrary.DYNAMIC_FEE_FLAG : r.fee;
        key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), keyFee, int24(1), IHooks(hook));
        pm.initialize(key, _centre());
        vm.startPrank(partner);
        s0.bind(key);
        s1.bind(key);
        s0.setKeeper(keeper, true);
        s1.setKeeper(keeper, true);
        vm.stopPrank();
        address[2] memory who = [partner, trader];
        for (uint256 i; i < 2; ++i) {
            deal(t0, who[i], 1e30);
            deal(t1, who[i], 1e30);
            vm.startPrank(who[i]);
            IERC20(t0).approve(hook, type(uint256).max);
            IERC20(t1).approve(hook, type(uint256).max);
            IERC20(t0).approve(address(router), type(uint256).max);
            IERC20(t1).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        // The hook's after-swap takes a swap's input before the swapper pays: a live PoolManager holds that much from
        // its other pools.
        deal(t0, address(pm), 1e30);
        deal(t1, address(pm), 1e30);
        (uint256 a0, uint256 a1) = _seed();
        vm.prank(partner);
        AnchoredUnlockCheckedHook(payable(hook)).seedLiquidity(a0, a1);
        if (!noFirstPass) _keeperPass();
    }

    // ---------------------------------------------------------------- reads

    function _price() internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(key.toId());
    }

    function _trader() internal view returns (int256) {
        return _value(IERC20(_token0()).balanceOf(trader), IERC20(_token1()).balanceOf(trader));
    }

    function _lps() internal view returns (int256) {
        address hook = address(key.hooks);
        return _value(
            s0.totalAssets() + IERC20(_token0()).balanceOf(hook), s1.totalAssets() + IERC20(_token1()).balanceOf(hook)
        );
    }

    /// @dev The smaller side's edge depth, 1% of its float target, valued as `_value` does.
    function _edge() internal view returns (uint256) {
        int256 e0 = _value(Math.mulDiv(s0.totalAssets(), s0.floatBps(), 1_000_000), 0);
        int256 e1 = _value(0, Math.mulDiv(s1.totalAssets(), s1.floatBps(), 1_000_000));
        return uint256(e0 < e1 ? e0 : e1);
    }

    // ---------------------------------------------------------------- moves

    function doSwap(bool zeroForOne, uint160 limit) external {
        require(msg.sender == address(this));
        vm.prank(trader, trader);
        router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e27), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev A swap to `limit`, or as far toward it as the pool's depth allows; one the hook cannot back changes nothing.
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

    // ---------------------------------------------------------------- the rounds

    /// @dev `ROUNDS` rounds: the push to an edge, alternately the lower and the upper, the keeper's pass five minutes on,
    /// and the trade back to the fair price in `BACK_STEPS` swaps. Returns the trader's cumulative gain at its highest,
    /// and after the last round, in basis points of the smaller side's edge depth at the start.
    function _rounds(Run memory r, uint256 n) internal returns (int256 worst, int256 end) {
        // A day of rounds runs past a test's gas limit: not what is measured here.
        vm.pauseGasMetering();
        _build(r);
        uint256 edge = _edge();
        int256 t0 = _trader();
        int256 l0 = _lps();
        worst = type(int256).min;
        for (uint256 i; i < n; ++i) {
            if (passBeforePush && i != 0) {
                vm.warp(block.timestamp + 5 minutes);
                _keeperPass();
            }
            _swapTo(_edgePrice(i % 2 == 0));
            vm.warp(block.timestamp + 5 minutes);
            _keeperPass();
            _stepTo(_fair(), backSteps);
            int256 at = (_trader() - t0) * 10_000 / int256(edge);
            if (at > worst) worst = at;
        }
        int256 gain = _trader() - t0;
        // A few raw units of rounding a swap, in the 18-decimal value, per round.
        assertApproxEqAbs(gain, l0 - _lps(), 1e15 * n, "the trader's gain is the LPs' loss");
        end = gain * 10_000 / int256(edge);
        vm.resumeGasMetering();
    }

    function _label(Run memory r) internal view returns (string memory) {
        return string.concat(
            r.declared == 0 ? "full range" : string.concat(vm.toString(r.declared), " ticks"),
            r.floatOnlyBps == 10_000
                ? ", kit layout, "
                : r.floatOnlyBps == EQUAL
                    ? ", equal targets, "
                    : string.concat(", other side at ", vm.toString(r.floatOnlyBps), " bps, "),
            vm.toString(lentBps / 100),
            "% float, ",
            vm.toString(r.fee / 100),
            " bp",
            feeHook
                ? (feeBack == 0 ? ", fee hook" : string.concat(", fee hook, ", vm.toString(feeBack / 100), " bp back"))
                : "",
            failsafeBps == 0 ? "" : string.concat(", failsafe ", vm.toString(failsafeBps / 100), "%"),
            passBeforePush ? ", a pass before each push" : "",
            bothLent ? ", both sides lent" : "",
            backSteps == BACK_STEPS ? "" : string.concat(", back in ", vm.toString(backSteps)),
            fairBps == 10_000 ? "" : string.concat(", fair at ", vm.toString(fairBps), " bps of the anchor")
        );
    }

    /// @dev The property at one width and layout, at a 20% and a 10% float target, at each fee, each on a fresh stack.
    function _holds(uint24 declared, uint16 floatOnlyBps) internal {
        uint16[2] memory floats = [uint16(2000), 1000];
        uint24[3] memory fees = [uint24(100), 500, 3000];
        for (uint256 j; j < floats.length; ++j) {
            lentBps = floats[j];
            for (uint256 i; i < fees.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                Run memory r = Run(declared, floatOnlyBps, fees[i], 0, 0);
                (int256 worst, int256 end) = _rounds(r, ROUNDS);
                console2.log(
                    string.concat(
                        _label(r),
                        ": worst cumulative LP loss (bps of the smaller edge) ",
                        vm.toString(worst),
                        ", after 288 rounds ",
                        vm.toString(end)
                    )
                );
                assertLe(worst, BAR, string.concat(_label(r), ": the LPs lost past a quarter of the edge depth"));
                vm.revertToStateAndDelete(snapshot);
            }
        }
        lentBps = 2000;
    }

    /// @dev The property with the fair price resting at each of `fairs` (basis points of the anchor), on one declared
    /// width with equal float targets on both sides, at each fee, each on a fresh stack.
    function _holdsOffAnchor(uint24 declared, uint256[2] memory fairs) internal {
        for (uint256 j; j < fairs.length; ++j) {
            fairBps = fairs[j];
            _holds(declared, EQUAL);
        }
        fairBps = 10_000;
    }

    /// @dev The property with the other side at its own float target `floatOnlyBps`, the fair price at the anchor and
    /// resting `off` basis points either side of it, at each float target of the lent side and each fee.
    function _holdsPerSide(uint24 declared, uint16 floatOnlyBps, uint256 off) internal {
        uint256[3] memory fairs = [uint256(10_000), 10_000 + off, 10_000 - off];
        for (uint256 j; j < fairs.length; ++j) {
            fairBps = fairs[j];
            _holds(declared, floatOnlyBps);
        }
        fairBps = 10_000;
    }

    /// @dev The kit's layout with the fair price resting off the anchor, at 1 bp: the deep side, reopened at the anchor
    /// each pass, pays the mispricing every round, past the bound within a day.
    function _breaksOffAnchor(uint24 declared, uint256 fair) internal returns (int256 worst) {
        return _offAnchor(declared, fair, 100);
    }

    /// @dev The same at `fee`.
    function _offAnchor(uint24 declared, uint256 fair, uint24 fee) internal returns (int256 worst) {
        fairBps = fair;
        Run memory r = Run(declared, 10_000, fee, 0, 0);
        (worst,) = _rounds(r, ROUNDS);
        console2.log(
            string.concat(_label(r), ": worst cumulative LP loss (bps of the smaller edge) ", vm.toString(worst))
        );
        fairBps = 10_000;
    }
}

/// @notice frxUSD/USDG, the keeper's +-0.5% band around parity, the anchor at parity: the stable pair the property and
/// the kit's anchored-hook tests run on.
abstract contract RehypoRepeatStablePair is RehypoRepeatBase {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRX = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    /// @dev 1 frxUSD for 1 USDG in raw units, as a v4 sqrt price.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);

    uint160 internal bandLo;
    uint160 internal bandHi;

    function setUp() public virtual override {
        super.setUp();
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), USDG);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), FRX);
        (bandLo, bandHi) = KitBands.around(PAR);
    }

    function _token0() internal pure override returns (address) {
        return FRX;
    }

    function _token1() internal pure override returns (address) {
        return USDG;
    }

    function _priceSource() internal pure override returns (address) {
        return address(0);
    }

    function _settings(uint24 declared) internal pure override returns (RehypoSourceSettings memory st) {
        st.rangeTicks = declared;
    }

    function _seed() internal pure override returns (uint256, uint256) {
        return (100_000e18, 100_000e6);
    }

    function _centre() internal pure override returns (uint160) {
        return PAR;
    }

    /// @dev 0.48% off parity, inside the +-0.5% band.
    function _edgePrice(bool below) internal pure override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(below ? 9952 : 10_048, 1 << 192, 1e4 * 1e12)));
    }

    function _keeperPass() internal override {
        vm.startPrank(keeper);
        s1.rebalance(bandLo, bandHi);
        s0.rebalance(bandLo, bandHi);
        vm.stopPrank();
    }

    function _fair() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(fairBps, 1 << 192, 1e4 * 1e12)));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, fairBps, 1e4) + a1 * 1e12);
    }
}

/// @notice The property on frxUSD/USDG.
contract RehypoSourceRepeatStableTest is RehypoRepeatStablePair {
    function test_repeat_fullRange_kitLayout() public {
        _holds(0, 10_000);
    }

    function test_repeat_fullRange_balanced() public {
        _holds(0, EQUAL);
    }

    function test_repeat_point5_kitLayout() public {
        _holds(100, 10_000);
    }

    function test_repeat_point5_balanced() public {
        _holds(100, EQUAL);
    }

    function test_repeat_point1_kitLayout() public {
        _holds(20, 10_000);
    }

    function test_repeat_point1_balanced() public {
        _holds(20, EQUAL);
    }

    function test_repeat_point05_kitLayout() public {
        _holds(10, 10_000);
    }

    function test_repeat_point05_balanced() public {
        _holds(10, EQUAL);
    }

    function test_repeat_point01_kitLayout() public {
        _holds(2, 10_000);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    /// @dev The anchored hook's range: parity plus and minus half the declared width, and the full range when a
    /// source declares it.
    function test_theAnchoredRangeSitsOnParity() public {
        _build(Run(20, 2000, 100, 0, 0));
        AnchoredUnlockCheckedHook hook = AnchoredUnlockCheckedHook(payable(address(key.hooks)));
        int24 parity = TickMath.getTickAtSqrtPrice(PAR);
        assertEq(hook.PARITY_TICK(), parity);
        assertEq(hook.getTickLower(), parity - 10);
        assertEq(hook.getTickUpper(), parity + 10);
        _swapTo(_edgePrice(true));
        assertEq(hook.getTickLower(), parity - 10, "a push moves nothing");
        _build(Run(0, 2000, 100, 0, 0));
        hook = AnchoredUnlockCheckedHook(payable(address(key.hooks)));
        assertEq(hook.getTickLower(), TickMath.minUsableTick(1));
        assertEq(hook.getTickUpper(), TickMath.maxUsableTick(1));
    }

    /// @dev The same rounds on a +-0.1% range re-centred at every swap break the bound well within a day: the property
    /// tells the shapes apart.
    function test_aRangeFollowingThePriceBreaksTheProperty() public {
        (int256 worst,) = _rounds(Run(20, 2000, 100, 2, 10), ROUNDS);
        console2.log("+-0.1% re-centred, balanced, 1 bp: worst cumulative LP loss (bps of the smaller edge)", worst);
        assertGt(worst, BAR, "a price-following range breaks the bound");
    }

    // ------------------------------------------------- frxUSD resting off parity inside the band, equal float targets

    /// @dev frxUSD worth 0.2% and 0.48% (the band's edge less the push's margin) more than parity.
    function test_offParity_above_point5() public {
        _holdsOffAnchor(100, [uint256(10_020), 10_048]);
    }

    function test_offParity_above_point1() public {
        _holdsOffAnchor(20, [uint256(10_020), 10_048]);
    }

    function test_offParity_above_point01() public {
        _holdsOffAnchor(2, [uint256(10_020), 10_048]);
    }

    function test_offParity_below_point5() public {
        _holdsOffAnchor(100, [uint256(9980), 9952]);
    }

    function test_offParity_below_point1() public {
        _holdsOffAnchor(20, [uint256(9980), 9952]);
    }

    function test_offParity_below_point01() public {
        _holdsOffAnchor(2, [uint256(9980), 9952]);
    }

    function test_repeat_point5_bothSidesLent() public {
        bothLent = true;
        _holds(100, EQUAL);
    }

    /// @dev With frxUSD lent too, resting off parity either way.
    function test_offParity_point5_bothSidesLent() public {
        bothLent = true;
        _holdsOffAnchor(100, [uint256(10_048), 9952]);
    }

    /// @dev The kit's layout (the float-only side at 100%) on a +-0.1% range with frxUSD 0.48% above parity breaks the
    /// bound within a day at 1 bp: why a stable pair takes equal float targets on a declared range.
    function test_offParity_kitLayoutBreaksTheProperty() public {
        assertGt(_breaksOffAnchor(20, 10_048), BAR, "the kit's layout off parity breaks the bound");
    }

    /// @dev The same layout and rest at a 5 bp fee breaks it too: on a range this much narrower than the rest off
    /// parity, a higher fee does not close the leak.
    function test_offParity_kitLayoutBreaksAtFiveBpToo() public {
        assertGt(_offAnchor(20, 10_048, 500), BAR, "at 5 bp the kit's layout off parity still breaks the bound");
    }
}

/// @notice NVDA/USDG at $180, both sources priced with a +-1% band centred on an honest signed report each keeper pass,
/// the anchor at the band's centre: the priced pair the property and the kit's anchored-hook tests run on.
abstract contract RehypoRepeatPricedPair is RehypoRepeatBase {
    address internal constant NVDA = 0x1000000000000000000000000000000000000001;
    address internal constant USDG = 0x2000000000000000000000000000000000000002;
    /// @dev $180, eight decimals.
    uint256 internal constant PRICE = 180e8;

    SignedPriceStandIn internal prices;
    uint160 internal par;
    /// @dev The kit's set-up script, for the width at which a band's cap stops binding (`capFreeTicks`).
    RehypoSource internal script = new RehypoSource();
    /// @dev Both sources' band either side of the signed price, and the NVDA seeded beside 100,000 USDG.
    uint16 internal bandBps = 100;
    uint256 internal seedNvda = 555e18;

    function setUp() public virtual override {
        super.setUp();
        deployCodeTo("RehypoSourcePricedPlug.t.sol:StockStandIn", "", NVDA);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), USDG);
        prices = new SignedPriceStandIn(USDG);
        par = uint160(Math.sqrt(Math.mulDiv(180e6, 1 << 192, 1e18)));
    }

    function _token0() internal pure override returns (address) {
        return NVDA;
    }

    function _token1() internal pure override returns (address) {
        return USDG;
    }

    function _priceSource() internal view override returns (address) {
        return address(prices);
    }

    function _settings(uint24 declared) internal view override returns (RehypoSourceSettings memory) {
        return RehypoSourceSettings(declared, address(prices), NVDA, bandBps, 500);
    }

    /// @dev About $100,000 a side, unless a test seeds more NVDA.
    function _seed() internal view override returns (uint256, uint256) {
        return (seedNvda, 100_000e6);
    }

    function _centre() internal view override returns (uint160) {
        return par;
    }

    /// @dev 95% of the way to the band's edge, inside it: 0.95% off the centre on the +-1% band.
    function _edgePrice(bool below) internal view override returns (uint160) {
        uint256 off = uint256(bandBps) * 95;
        return uint160(Math.mulDiv(par, Math.sqrt((below ? 1e6 - off : 1e6 + off) * 1e12), 1e9));
    }

    function _keeperPass() internal override {
        bytes memory report = abi.encode(PRICE, block.timestamp);
        vm.startPrank(keeper);
        s1.rebalanceAt(report);
        s0.rebalanceAt(report);
        vm.stopPrank();
    }

    /// @dev The venue's fair price, `fairBps` of the signed price the keeper centres on each pass.
    function _fair() internal view override returns (uint160) {
        return uint160(Math.mulDiv(par, Math.sqrt(fairBps * 1e14), 1e9));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, PRICE * 1e6 * fairBps, 1e26 * 1e4) + a1) * 1e12;
    }
}

/// @notice The property on NVDA/USDG.
contract RehypoSourceRepeatPricedTest is RehypoRepeatPricedPair {
    function test_repeat_fullRange_kitLayout() public {
        _holds(0, 10_000);
    }

    function test_repeat_fullRange_balanced() public {
        _holds(0, EQUAL);
    }

    function test_repeat_onePct_kitLayout() public {
        _holds(200, 10_000);
    }

    function test_repeat_onePct_balanced() public {
        _holds(200, EQUAL);
    }

    function test_repeat_point5_kitLayout() public {
        _holds(100, 10_000);
    }

    function test_repeat_point5_balanced() public {
        _holds(100, EQUAL);
    }

    function test_repeat_point1_kitLayout() public {
        _holds(20, 10_000);
    }

    function test_repeat_point1_balanced() public {
        _holds(20, EQUAL);
    }

    function test_repeat_point05_kitLayout() public {
        _holds(10, 10_000);
    }

    function test_repeat_point05_balanced() public {
        _holds(10, EQUAL);
    }

    function test_repeat_point01_kitLayout() public {
        _holds(2, 10_000);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    /// @dev The anchored range sized at each swap's price instead of the anchor: on the kit's layout at the band's width
    /// a push through the thin centre is traded back in steps through the deeper liquidity near the edge, and the bound
    /// breaks within a day.
    function test_aRangeSizedAtThePriceBreaksTheProperty() public {
        (int256 worst,) = _rounds(Run(200, 10_000, 100, 1, 100), ROUNDS);
        console2.log("+-1% at the centre, sized at the price, kit layout, 1 bp: worst cumulative LP loss", worst);
        assertGt(worst, BAR, "a range sized at the price breaks the bound");
    }

    /// @dev The anchored hook's range on a priced pair: the full range before the first centre, then the centre plus
    /// and minus half the declared width, moved only by the keeper's next centre.
    function test_theAnchoredRangeSitsOnTheCentre() public {
        _build(Run(20, 2000, 100, 0, 0));
        AnchoredUnlockCheckedHook hook = AnchoredUnlockCheckedHook(payable(address(key.hooks)));
        int24 centre = TickMath.getTickAtSqrtPrice(par);
        (bool set, int24 anchor) = hook.anchorTick();
        assertTrue(set);
        assertApproxEqAbs(anchor, centre, 1, "the band's centre");
        assertEq(hook.getTickLower(), anchor - 10);
        assertEq(hook.getTickUpper(), anchor + 10);
        _swapTo(_edgePrice(true));
        assertEq(hook.getTickLower(), anchor - 10, "a push moves nothing");
    }

    // --------------------------------------- the venue resting off the signed price inside the band, equal targets

    /// @dev NVDA worth 0.2% and 0.95% (the band's edge less the push's margin) more than the signed price.
    function test_offCentre_above_onePct() public {
        _holdsOffAnchor(200, [uint256(10_020), 10_095]);
    }

    function test_offCentre_above_point1() public {
        _holdsOffAnchor(20, [uint256(10_020), 10_095]);
    }

    function test_offCentre_above_point01() public {
        _holdsOffAnchor(2, [uint256(10_020), 10_095]);
    }

    function test_offCentre_below_onePct() public {
        _holdsOffAnchor(200, [uint256(9980), 9905]);
    }

    function test_offCentre_below_point1() public {
        _holdsOffAnchor(20, [uint256(9980), 9905]);
    }

    function test_offCentre_below_point01() public {
        _holdsOffAnchor(2, [uint256(9980), 9905]);
    }

    function test_repeat_onePct_bothSidesLent() public {
        bothLent = true;
        _holds(200, EQUAL);
    }

    /// @dev With NVDA lent too, the venue resting off the signed price either way.
    function test_offCentre_onePct_bothSidesLent() public {
        bothLent = true;
        _holdsOffAnchor(200, [uint256(10_095), 9905]);
    }

    // ------------------------------------------------- a float target per side, where the cap leaves the float free

    /// @dev A priced, unpegged pair may give its two sides different float targets where its declared range is at
    /// least the width at which the source's cap inside the band stops binding for its band (`capFreeTicks`, the kit's
    /// set-up script): there the property holds as it does with equal targets, the other side at 100% or at a
    /// thirtieth, the fair price at the anchor and 90% of the way to the band's edge either way. Below that width it
    /// breaks at the 1 bp fee, which is why gage warns of different targets on a narrower range.
    function test_perSide_band25_otherSideWhole() public {
        bandBps = 25;
        _holdsPerSide(script.capFreeTicks(25), 10_000, 22);
    }

    function test_perSide_band25_otherSideThin() public {
        bandBps = 25;
        _holdsPerSide(script.capFreeTicks(25), 300, 22);
    }

    function test_perSide_band50_otherSideWhole() public {
        bandBps = 50;
        _holdsPerSide(script.capFreeTicks(50), 10_000, 45);
    }

    function test_perSide_band50_otherSideThin() public {
        bandBps = 50;
        _holdsPerSide(script.capFreeTicks(50), 300, 45);
    }

    function test_perSide_band100_otherSideWhole() public {
        _holdsPerSide(script.capFreeTicks(100), 10_000, 90);
    }

    function test_perSide_band100_otherSideThin() public {
        _holdsPerSide(script.capFreeTicks(100), 300, 90);
    }

    /// @dev A pool that holds nine times more NVDA than USDG, the NVDA side at a thirtieth: about the same dollars in
    /// the pool on each side, as a stock or ETH pool is set.
    function test_perSide_onAPoolOfMostlyTheOtherToken() public {
        (bandBps, seedNvda) = (30, 5000e18);
        _holdsPerSide(script.capFreeTicks(30), 340, 27);
    }

    /// @dev At a quarter of the width, 20% beside 100% at 1 bp with NVDA 0.45% above the signed price: past the bound.
    function test_perSide_belowTheCapFreeWidthBreaksTheProperty() public {
        bandBps = 50;
        assertGt(
            _breaksOffAnchor(script.capFreeTicks(50) / 4, 10_045),
            BAR,
            "different targets under the cap break the bound"
        );
    }

    /// @dev The same range and rest at a 5 bp fee stays under the bound: here the range is wider than the rest off
    /// the signed price, and the fee closes the leak.
    function test_perSide_belowTheCapFreeWidthHoldsAtFiveBp() public {
        bandBps = 50;
        assertLt(_offAnchor(script.capFreeTicks(50) / 4, 10_045, 500), BAR, "at 5 bp different targets hold");
    }

    /// @dev The kit's layout on a +-1% range with NVDA 0.2% above the signed price breaks the bound within a day at 1
    /// bp: why equal float targets are the default on a priced pair too.
    function test_offCentre_kitLayoutBreaksTheProperty() public {
        assertGt(_breaksOffAnchor(200, 10_020), BAR, "the kit's layout off the signed price breaks the bound");
    }
}

/// @notice A dollar stable's signed price, `NuntiusPriceSource`'s surface in this kit's compiler: the report is the price
/// (eight decimals) and its time, refused older than five minutes; no Stock Token.
contract StablePriceStandIn {
    address public immutable USDG;

    error StalePrice(address token, uint256 timestamp);

    constructor(address usdg) {
        USDG = usdg;
    }

    function assetOf(address) external pure returns (bytes32, uint32, uint8, uint8, bool) {
        return (keccak256("frxUSD/USD"), 5 minutes, 1, 18, false);
    }

    function valueOf(address token, uint256 amount, bytes calldata report) external view returns (uint256, uint256) {
        (uint256 price, uint256 at) = abi.decode(report, (uint256, uint256));
        if (at + 5 minutes < block.timestamp || at > block.timestamp + 1 minutes) revert StalePrice(token, at);
        return (Math.mulDiv(amount, price * 1e6, 1e26), at);
    }
}

/// @notice frxUSD/USDG pegged (`PEG_BPS` 0.5%): both sources centre a +-0.5% band on frxUSD's signed price each keeper
/// pass, the anchor at the band's centre, and open their whole float inside the band.
abstract contract RehypoRepeatPeggedPair is RehypoRepeatBase {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRX = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    uint16 internal constant PEG = 50;

    StablePriceStandIn internal prices;
    /// @dev The signed price the keeper brings, eight decimals.
    uint256 internal price8 = 1e8;

    function setUp() public virtual override {
        super.setUp();
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), USDG);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), FRX);
        prices = new StablePriceStandIn(USDG);
    }

    function _token0() internal pure override returns (address) {
        return FRX;
    }

    function _token1() internal pure override returns (address) {
        return USDG;
    }

    function _priceSource() internal view override returns (address) {
        return address(prices);
    }

    function _settings(uint24 declared) internal view override returns (RehypoSourceSettings memory) {
        return RehypoSourceSettings(declared, address(prices), FRX, 50, 100);
    }

    function _peg() internal pure override returns (uint16) {
        return PEG;
    }

    function _seed() internal pure override returns (uint256, uint256) {
        return (100_000e18, 100_000e6);
    }

    /// @dev frxUSD at the signed price, in raw USDG per raw frxUSD, as a v4 sqrt price.
    function _centre() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8, 1 << 192, 1e8 * 1e12)));
    }

    /// @dev 0.48% off the centre, inside the +-0.5% band.
    function _edgePrice(bool below) internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8 * (below ? 9952 : 10_048), 1 << 192, 1e8 * 1e4 * 1e12)));
    }

    function _keeperPass() internal virtual override {
        bytes memory report = abi.encode(price8, block.timestamp);
        vm.startPrank(keeper);
        s1.rebalanceAt(report);
        s0.rebalanceAt(report);
        vm.stopPrank();
    }

    /// @dev The venue's fair price, `fairBps` of the signed price the keeper centres on.
    function _fair() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8 * fairBps, 1 << 192, 1e8 * 1e4 * 1e12)));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, price8 * fairBps, 1e8 * 1e4) + a1 * 1e12);
    }
}

/// @notice The property on frxUSD/USDG pegged.
contract RehypoSourceRepeatPeggedTest is RehypoRepeatPeggedPair {
    /// @dev Off the peg the keeper's pass reverts and the rounds go on without it.
    bool internal passMayFail;

    function _keeperPass() internal override {
        if (!passMayFail) return super._keeperPass();
        bytes memory report = abi.encode(price8, block.timestamp);
        vm.startPrank(keeper);
        try s1.rebalanceAt(report) {} catch {}
        try s0.rebalanceAt(report) {} catch {}
        vm.stopPrank();
    }

    function test_repeat_fullRange_kitLayout() public {
        _holds(0, 10_000);
    }

    function test_repeat_fullRange_balanced() public {
        _holds(0, EQUAL);
    }

    function test_repeat_point5_kitLayout() public {
        _holds(100, 10_000);
    }

    function test_repeat_point5_balanced() public {
        _holds(100, EQUAL);
    }

    function test_repeat_point1_kitLayout() public {
        _holds(20, 10_000);
    }

    function test_repeat_point1_balanced() public {
        _holds(20, EQUAL);
    }

    function test_repeat_point05_balanced() public {
        _holds(10, EQUAL);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    /// @dev Inside the band the pegged range opens its whole float target, where the same range unpegged opens its
    /// in-band cap: the depth the 10% float buys.
    function test_aPeggedRangeOpensItsWholeFloat() public {
        lentBps = 1000;
        _build(Run(20, EQUAL, 100, 0, 0));
        assertEq(s1.swapCap(), type(uint256).max, "no in-band cap");
        assertEq(s1.swapFloat(), s1.totalAssets() / 10, "the whole 10% target opens");
        assertEq(s0.swapFloat(), s0.totalAssets() / 10, "on both sides");
    }

    // --------------------------------------- the venue resting off the signed price inside the band, equal targets

    /// @dev frxUSD's venue 0.2% and 0.48% (the band's edge less the push's margin) over the signed price.
    function test_offCentre_above_point5() public {
        _holdsOffAnchor(100, [uint256(10_020), 10_048]);
    }

    function test_offCentre_above_point1() public {
        _holdsOffAnchor(20, [uint256(10_020), 10_048]);
    }

    function test_offCentre_below_point5() public {
        _holdsOffAnchor(100, [uint256(9980), 9952]);
    }

    /// @dev Below the signed price a +-0.1% range holds the bound with the venue up to 0.25% under it.
    function test_offCentre_below_point1() public {
        _holdsOffAnchor(20, [uint256(9980), 9975]);
    }

    /// @dev Further below, the whole float reopened at the signed price is past the bound in one round: with the venue
    /// resting 0.48% under the signed price, the first trade back takes 0.42 of the edge depth (the bar is a quarter),
    /// about the gap times the float, and no later round adds to it, at a 20% or a 10% float. The in-band cap held this
    /// round to a share of the float; without it, a gap between the venue and the signed price costs the LPs up to the
    /// gap on the float once each time it opens, what the keeper's check of a local reference is to catch.
    function test_offCentre_below_point1_aWideGapCostsOneRound() public {
        uint16[2] memory floats = [uint16(2000), 1000];
        for (uint256 k; k < floats.length; ++k) {
            lentBps = floats[k];
            fairBps = 9952;
            uint256 snapshot = vm.snapshotState();
            (int256 first, int256 worst) = _firstAndWorst(Run(20, EQUAL, 100, 0, 0));
            vm.revertToStateAndDelete(snapshot);
            console2.log(
                string.concat(
                    "venue 0.48% under, 20 ticks, ",
                    vm.toString(lentBps / 100),
                    "% float, 1 bp: first round ",
                    vm.toString(first),
                    ", worst ",
                    vm.toString(worst)
                )
            );
            assertGt(worst, BAR, "past the bound");
            assertLe(worst, first + 10, "in the first round, never after");
            assertLe(worst, 4500, "about the gap on the float: 0.48% of a hundred edge depths is 4,800");
        }
        fairBps = 10_000;
        lentBps = 2000;
    }

    /// @dev The first round's gain and the highest cumulative gain over a day of rounds, in basis points of the edge.
    function _firstAndWorst(Run memory r) internal returns (int256 first, int256 worst) {
        vm.pauseGasMetering();
        _build(r);
        uint256 edge = _edge();
        int256 t0 = _trader();
        worst = type(int256).min;
        for (uint256 i; i < ROUNDS; ++i) {
            _swapTo(_edgePrice(i % 2 == 0));
            vm.warp(block.timestamp + 5 minutes);
            _keeperPass();
            _stepTo(_fair(), BACK_STEPS);
            int256 at = (_trader() - t0) * 10_000 / int256(edge);
            if (i == 0) first = at;
            if (at > worst) worst = at;
        }
        vm.resumeGasMetering();
    }

    // --------------------------------------- off the peg, and a depeg the feed does not see

    /// @dev frxUSD signed and traded 1% under a dollar, past the 0.5% peg, for a day of rounds: every keeper pass reverts,
    /// so nothing reopens, and the trader takes once what the last pass left at the old centre, never again: the loss
    /// after 288 rounds is what the first round took, and the next day adds nothing.
    function test_offThePegTheRoundsTakeOnlyWhatTheLastPassLeft() public {
        lentBps = 1000;
        Run memory r = Run(20, EQUAL, 100, 0, 0);
        vm.pauseGasMetering();
        _build(r);
        // frxUSD falls 1% below a dollar, everywhere: the feed signs it and the venue trades it, so value at 99 cents.
        passMayFail = true;
        price8 = 0.99e8;
        uint256 edge = _edge();
        int256 t0 = _trader();
        int256[3] memory at;
        for (uint256 i; i < 2 * ROUNDS; ++i) {
            _swapTo(_edgePrice(i % 2 == 0));
            vm.warp(block.timestamp + 5 minutes);
            _keeperPass();
            _stepTo(_fair(), BACK_STEPS);
            if (i == 0) at[0] = (_trader() - t0) * 10_000 / int256(edge);
            if (i == ROUNDS - 1) at[1] = (_trader() - t0) * 10_000 / int256(edge);
        }
        at[2] = (_trader() - t0) * 10_000 / int256(edge);
        vm.resumeGasMetering();
        console2.log("1% under the peg, 10% float: after one round, a day and two days (bps of the edge)", at[0]);
        console2.log(at[1]);
        console2.log(at[2]);
        assertLe(at[1], at[0] + 10, "off the peg the rounds take no more than the first did");
        assertLe(at[2], at[1] + 10, "and the next day adds nothing");
    }

    /// @dev A depeg the global feed does not see: frxUSD trades 1% under a dollar locally while the feed still signs a
    /// dollar, inside the peg, so every keeper pass reopens the whole float at a dollar. The first trade back takes
    /// about 1% of the float, past the bound, as much as a depeg the feed does see takes before the peg stops the
    /// passes: what the keeper's check of a local reference must catch before it sends a pass.
    function test_aLocalDepegTheFeedMissesBreaksTheBound() public {
        fairBps = 9900;
        lentBps = 1000;
        (int256 first, int256 worst) = _firstAndWorst(Run(20, EQUAL, 100, 0, 0));
        fairBps = 10_000;
        console2.log(
            string.concat(
                "local depeg 1%, feed at a dollar, 10% float: first round ",
                vm.toString(first),
                ", worst ",
                vm.toString(worst),
                " (bps of the edge)"
            )
        );
        assertGt(worst, BAR, "a local depeg the feed misses is past the bound");
        assertLe(worst, 10_000, "about 1% of the float: a hundred edge depths' 1%");
    }
}

/// @notice The property on the kit's fee hook (`AnchoredFeeHook`), frxUSD/USDG on a dynamic-fee pool: its module
/// quoting 1, 5 and 30 bp, and a different fee each way, at the widest and the narrowest widths in both layouts.
/// `test/AnchoredFeeHook.t.sol` shows it trades, at one fee, exactly as the static-fee hooks do.
contract RehypoSourceRepeatStableFeeHookTest is RehypoRepeatStablePair {
    function setUp() public override {
        super.setUp();
        feeHook = true;
    }

    function test_repeat_fullRange_kitLayout() public {
        _holds(0, 10_000);
    }

    function test_repeat_point5_balanced() public {
        _holds(100, EQUAL);
    }

    function test_repeat_point01_kitLayout() public {
        _holds(2, 10_000);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    /// @dev Each fee one way against 30 bp, then against 1 bp, the other way.
    function test_repeat_point1_balanced_aDifferentFeeEachWay() public {
        feeBack = 3000;
        _holds(20, EQUAL);
        feeBack = 100;
        _holds(20, EQUAL);
    }
}

/// @notice The property on the kit's fee hook, a priced pair (NVDA/USDG).
contract RehypoSourceRepeatPricedFeeHookTest is RehypoRepeatPricedPair {
    function setUp() public override {
        super.setUp();
        feeHook = true;
    }

    function test_repeat_fullRange_balanced() public {
        _holds(0, EQUAL);
    }

    function test_repeat_onePct_kitLayout() public {
        _holds(200, 10_000);
    }

    function test_repeat_point01_kitLayout() public {
        _holds(2, 10_000);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    function test_repeat_point5_kitLayout_aDifferentFeeEachWay() public {
        feeBack = 3000;
        _holds(100, 10_000);
        feeBack = 100;
        _holds(100, 10_000);
    }
}

/// @notice The property on the kit's fee hook, a pegged pair (frxUSD/USDG on its signed price), whose whole float is
/// open inside the band.
contract RehypoSourceRepeatPeggedFeeHookTest is RehypoRepeatPeggedPair {
    function setUp() public override {
        super.setUp();
        feeHook = true;
    }

    function test_repeat_fullRange_kitLayout() public {
        _holds(0, 10_000);
    }

    function test_repeat_point5_kitLayout() public {
        _holds(100, 10_000);
    }

    function test_repeat_point01_balanced() public {
        _holds(2, EQUAL);
    }

    function test_repeat_point1_balanced_aDifferentFeeEachWay() public {
        feeBack = 3000;
        _holds(20, EQUAL);
        feeBack = 100;
        _holds(20, EQUAL);
    }
}

/// @notice The property on frxUSD/USDG pegged with the failsafe on both sources and the anchored failsafe hook's ask of
/// both (`AnchoredFailsafeUnlockCheckedHook._askBoth`), against the trader the ask serves best: a keeper pass before
/// every push, so the push sizes the position afresh and draws a tenth of each side's backing on top of its float, and
/// the trade back in one swap after the next pass, which draws again. Every swap of the day takes the deepened
/// position; the LPs' loss stays under the same bound as without the failsafe.
contract RehypoSourceRepeatPeggedFailsafeTest is RehypoRepeatPeggedPair {
    function setUp() public override {
        super.setUp();
        failsafeBps = 1000;
    }

    function test_repeat_point5_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holds(100, EQUAL);
    }

    function test_repeat_point25_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holds(50, EQUAL);
    }

    function test_repeat_point1_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holds(20, EQUAL);
    }

    /// @dev The same rounds as without the failsafe: the push holds what the trade back left, and only the trade
    /// back's first step could ask.
    function test_repeat_point25_theUsualRounds() public {
        _holds(50, EQUAL);
    }

    function test_repeat_point25_everySwapAsks_feeHook() public {
        (passBeforePush, backSteps, feeHook) = (true, 1, true);
        _holds(50, EQUAL);
    }

    /// @dev frxUSD's venue 0.2% over the signed price: the fair price rests off the anchor.
    function test_offCentre_point25_everySwapAsks() public {
        (passBeforePush, backSteps) = (true, 1);
        _holdsOffAnchor(50, [uint256(10_020), 9980]);
    }

    /// @dev Those rounds do draw: the push after a keeper pass takes each side's whole room, and so does the one-swap
    /// trade back after the next pass.
    function test_inThoseRoundsEveryPushAndTradeBackDraws() public {
        vm.pauseGasMetering();
        _build(Run(50, EQUAL, 500, 0, 0));
        uint256 cash = vault.cash();
        assertGt(IRepeatRoom(address(s0)).failsafeLeft(), 0);
        _swapTo(_edgePrice(true));
        assertLe(IRepeatRoom(address(s0)).failsafeLeft(), 1e12, "the push took the frxUSD room");
        assertLe(IRepeatRoom(address(s1)).failsafeLeft(), 1, "and the USDG room, from the vault");
        assertLt(vault.cash(), cash);
        vm.warp(block.timestamp + 5 minutes);
        _keeperPass();
        cash = vault.cash();
        _stepTo(_fair(), 1);
        assertLe(IRepeatRoom(address(s1)).failsafeLeft(), 1, "the trade back took it again");
        assertLt(vault.cash(), cash);
        vm.resumeGasMetering();
    }
}

interface IRepeatRoom {
    function failsafeLeft() external view returns (uint256);
}
