// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RehypoRepeatBase, StablePriceStandIn} from "../RehypoSourceRepeat.t.sol";
import {SignedPriceStandIn} from "../RehypoSourcePricedPlug.t.sol";
import {RehypoSourceSettings} from "../../script/RehypoSource.s.sol";
import {KitBands} from "./KitBands.sol";
import {FeeModuleStandIn} from "../mocks/FeeModuleStandIn.sol";
import {StandingPosition} from "../../src/StandingAnchoredHook.sol";

/// @notice The repeat rounds' stack (`RehypoRepeatBase`: the PoolManager, gage's two sources, the trader and the
/// rounds' moves) on the kit's standing hooks (`src/StandingAnchoredHook.sol`, `src/StandingFeeHook.sol`): the hook is
/// the sources' only keeper and `keeper` the hook's, so a keeper pass is one call to the hook. The LPs' value counts
/// the position the hook leaves in the pool, which the sources' `totalAssets` does not.
abstract contract StandingBase is RehypoRepeatBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev A standing hook's permissions: the anchored hooks' less `afterSwap`.
    uint160 internal constant STANDING_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
    );

    /// @dev When an LP holder takes the position out in a round: never, right after the push, right after the
    /// keeper's pass (before the trade back, where the pass has left it out already), or before every swap of the round, so that each swap places the position
    /// again and the sources' caps apply at each, as on the anchored hook.
    uint8 internal constant NEVER = 0;
    uint8 internal constant AFTER_PUSH = 1;
    uint8 internal constant AFTER_PASS = 2;
    uint8 internal constant EVERY_SWAP = 3;

    address internal stranger = makeAddr("stranger");

    function _hook() internal view returns (StandingPosition) {
        return StandingPosition(payable(address(key.hooks)));
    }

    /// @dev The keeper's call to the hook for one pass: `rebalance` with the band on a stable pair, `rebalanceAt` with
    /// a report on a priced or pegged one.
    function _moveData() internal view virtual returns (bytes memory);

    function _pass() internal {
        bytes memory data = _moveData();
        vm.prank(keeper);
        (bool ok, bytes memory reason) = address(key.hooks).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _keeperPass() internal override {
        _pass();
    }

    // ---------------------------------------------------------------- the stack

    /// @dev `RehypoRepeatBase._build` on a standing hook: the plain one, the failsafe one with `failsafeBps`, and
    /// their fee twins with `feeHook`. The partner names the hook keeper on both sources and `keeper` on the hook.
    /// Nothing is dealt to the PoolManager: a standing hook takes nothing before a swapper pays.
    function _buildStanding(Run memory r) internal {
        address t0 = _token0();
        address t1 = _token1();
        _sources(r);
        address hook = address(STANDING_FLAGS | (uint160(++salt) << 144));
        if (feeHook) {
            feeModule = new FeeModuleStandIn();
            feeModule.set(FEE_POOL, r.fee, feeBack == 0 ? r.fee : feeBack);
            deployCodeTo(
                failsafeBps == 0
                    ? "StandingFeeHook.sol:StandingAnchoredFeeHook"
                    : "StandingFeeHook.sol:StandingAnchoredFailsafeFeeHook",
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
        } else {
            deployCodeTo(
                failsafeBps == 0
                    ? "StandingAnchoredHook.sol:StandingAnchoredHook"
                    : "StandingAnchoredHook.sol:StandingAnchoredFailsafeHook",
                failsafeBps == 0
                    ? abi.encode(address(pm), address(s0), address(s1))
                    : abi.encode(address(pm), address(s0), address(s1), drawFee0, drawFee1, forgonePips),
                hook
            );
        }
        key = PoolKey(
            Currency.wrap(t0),
            Currency.wrap(t1),
            feeHook ? LPFeeLibrary.DYNAMIC_FEE_FLAG : r.fee,
            int24(1),
            IHooks(hook)
        );
        pm.initialize(key, _centre());
        vm.startPrank(partner);
        s0.bind(key);
        s1.bind(key);
        s0.setKeeper(hook, true);
        s1.setKeeper(hook, true);
        StandingPosition(payable(hook)).setKeeper(keeper, true);
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
        (uint256 a0, uint256 a1) = _seed();
        vm.prank(partner);
        StandingPosition(payable(hook)).seedLiquidity(a0, a1);
        if (!noFirstPass) _pass();
    }

    /// @dev `RehypoRepeatBase._build` on the kit's anchored hook, for a comparison: `keeper` is the sources' own
    /// keeper there, and a pass calls each source.
    function _buildAnchored(Run memory r) internal {
        bool skip = noFirstPass;
        noFirstPass = true;
        _build(r);
        noFirstPass = skip;
        if (!skip) _passSources();
    }

    /// @dev A keeper pass on the sources themselves, as the anchored hooks' keeper sends it: the hook's move data is
    /// the sources' own call.
    function _passSources() internal {
        bytes memory data = _moveData();
        vm.startPrank(keeper);
        (bool ok1,) = address(s1).call(data);
        (bool ok0,) = address(s0).call(data);
        vm.stopPrank();
        require(ok0 && ok1, "a source refused the pass");
    }

    // ---------------------------------------------------------------- reads

    /// @dev The swap fees the position has earned since it was placed, which stay in the pool until it is next taken
    /// out: the hook's `positionAmounts` and share quotes leave them out.
    function _uncollected() internal view returns (uint256 fees0, uint256 fees1) {
        (uint128 liquidity, int24 lower, int24 upper) = _hook().position();
        if (liquidity == 0) return (0, 0);
        PoolId id = key.toId();
        (, uint256 last0, uint256 last1) = pm.getPositionInfo(id, address(key.hooks), lower, upper, bytes32(0));
        (uint256 inside0, uint256 inside1) = pm.getFeeGrowthInside(id, lower, upper);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, 1 << 128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, 1 << 128);
        }
    }

    /// @dev What the LPs hold of each coin: both sources' backing, the position in the pool with its fees, and anything
    /// left on the hook.
    function _backing() internal view returns (uint256 b0, uint256 b1) {
        address hook = address(key.hooks);
        (uint256 p0, uint256 p1) = _hook().positionAmounts();
        (uint256 f0, uint256 f1) = _uncollected();
        b0 = s0.totalAssets() + p0 + f0 + IERC20(_token0()).balanceOf(hook);
        b1 = s1.totalAssets() + p1 + f1 + IERC20(_token1()).balanceOf(hook);
    }

    /// @dev `shares`' part of the fees not yet collected, as the hook prices shares (its virtual shares counted).
    function _feeShare(uint256 shares) internal view returns (uint256 f0, uint256 f1) {
        (f0, f1) = _uncollected();
        uint256 supply = _hook().totalSupply() + 1e6;
        (f0, f1) = (Math.mulDiv(f0, shares, supply), Math.mulDiv(f1, shares, supply));
    }

    /// @dev What `shares` are worth of each coin: the hook's quote and their part of the fees not yet collected.
    function _redeems(uint256 shares) internal view returns (uint256 r0, uint256 r1) {
        (r0, r1) = _hook().previewRedeem(shares);
        (uint256 f0, uint256 f1) = _feeShare(shares);
        (r0, r1) = (r0 + f0, r1 + f1);
    }

    function _lpsStanding() internal view returns (int256) {
        (uint256 b0, uint256 b1) = _backing();
        return _value(b0, b1);
    }

    /// @dev The smaller side's edge depth, 1% of its float target, on the whole backing (the position counted).
    function _edgeStanding() internal view returns (uint256) {
        (uint256 b0, uint256 b1) = _backing();
        int256 e0 = _value(Math.mulDiv(b0, s0.floatBps(), 1_000_000), 0);
        int256 e1 = _value(0, Math.mulDiv(b1, s1.floatBps(), 1_000_000));
        return uint256(e0 < e1 ? e0 : e1);
    }

    /// @dev The accesses a recorded stretch made to either source or the vault: calls, static calls, code reads.
    function _sourceAccesses(Vm.AccountAccess[] memory accesses) internal view returns (uint256 n) {
        for (uint256 i; i < accesses.length; ++i) {
            address a = accesses[i].account;
            if (a == address(s0) || a == address(s1) || a == address(vault)) ++n;
        }
    }

    function _liquidity() internal view returns (uint128 liquidity) {
        (liquidity,,) = _hook().position();
    }

    /// @dev A swap that moves nothing to speak of: one raw unit in, stopped one sqrt-price unit away. It places a
    /// position that is out, as the first swap after a keeper move does.
    function _dustSwap() internal {
        uint160 p = _price();
        this.swapExact(true, -1, p - 1);
    }

    /// @dev What the next swap would place, read on a copy of the state: the position's liquidity.
    function _placing() internal returns (uint128 liquidity) {
        uint256 snapshot = vm.snapshotState();
        _dustSwap();
        liquidity = _liquidity();
        vm.revertToStateAndDelete(snapshot);
    }

    // ---------------------------------------------------------------- moves

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

    /// @dev The gas of one swap by the trader through the test router.
    function _swapGas(bool zeroForOne, int256 amount, uint160 limit) internal returns (uint256) {
        vm.prank(trader, trader);
        router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return vm.lastCallGas().gasTotalUsed;
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

    // ---------------------------------------------------------------- the rounds

    /// @dev `RehypoRepeatBase._rounds` on a standing hook, an LP holder taking the position out at `takeOutAt` in
    /// every round.
    function _roundsStanding(Run memory r, uint256 n, uint8 takeOutAt) internal returns (int256 worst, int256 end) {
        vm.pauseGasMetering();
        _buildStanding(r);
        uint256 edge = _edgeStanding();
        int256 t0 = _trader();
        int256 l0 = _lpsStanding();
        worst = type(int256).min;
        for (uint256 i; i < n; ++i) {
            if (passBeforePush && i != 0) {
                vm.warp(block.timestamp + 5 minutes);
                _pass();
            }
            if (takeOutAt == EVERY_SWAP) _holderTakesOut();
            _swapTo(_edgePrice(i % 2 == 0));
            if (takeOutAt == AFTER_PUSH) _holderTakesOut();
            vm.warp(block.timestamp + 5 minutes);
            _pass();
            if (takeOutAt == AFTER_PASS) _holderTakesOut();
            if (takeOutAt == EVERY_SWAP) _stepToTakingOut(_fair(), backSteps);
            else _stepTo(_fair(), backSteps);
            int256 at = (_trader() - t0) * 10_000 / int256(edge);
            if (at > worst) worst = at;
        }
        int256 gain = _trader() - t0;
        // A few raw units of rounding a swap, in the 18-decimal value, per round.
        assertApproxEqAbs(gain, l0 - _lpsStanding(), 1e15 * n, "the trader's gain is the LPs' loss");
        end = gain * 10_000 / int256(edge);
        vm.resumeGasMetering();
    }

    /// @dev `RehypoRepeatBase._stepTo`, the position taken out before each step.
    function _stepToTakingOut(uint160 limit, uint256 n) internal {
        uint160 p = _price();
        for (uint256 i = 1; i <= n; ++i) {
            uint256 next = limit > p
                ? uint256(p) + (uint256(limit) - uint256(p)) * i / n
                : uint256(p) - (uint256(p) - uint256(limit)) * i / n;
            _holderTakesOut();
            _swapTo(uint160(next));
        }
    }

    /// @dev The same rounds on the kit's anchored hook (`_buildAnchored`), its keeper calling the sources: what the
    /// standing hook's are compared with.
    function _roundsAnchored(Run memory r, uint256 n) internal returns (int256 worst, int256 end) {
        vm.pauseGasMetering();
        _buildAnchored(r);
        uint256 edge = _edge();
        int256 t0 = _trader();
        worst = type(int256).min;
        for (uint256 i; i < n; ++i) {
            if (passBeforePush && i != 0) {
                vm.warp(block.timestamp + 5 minutes);
                _passSources();
            }
            _swapTo(_edgePrice(i % 2 == 0));
            vm.warp(block.timestamp + 5 minutes);
            _passSources();
            _stepTo(_fair(), backSteps);
            int256 at = (_trader() - t0) * 10_000 / int256(edge);
            if (at > worst) worst = at;
        }
        end = (_trader() - t0) * 10_000 / int256(edge);
        vm.resumeGasMetering();
    }

    function _holderTakesOut() internal {
        vm.prank(partner);
        _hook().takeOut();
    }

    function _labelStanding(Run memory r, uint8 takeOutAt) internal view returns (string memory) {
        return string.concat(
            "standing, ",
            _label(r),
            takeOutAt == NEVER
                ? ""
                : takeOutAt == AFTER_PUSH
                    ? ", taken out after each push"
                    : takeOutAt == AFTER_PASS ? ", taken out after each pass" : ", taken out before every swap"
        );
    }

    /// @dev The property at one width and layout, at a 20% and a 10% float target, at each fee, each on a fresh stack.
    function _holdsStanding(uint24 declared, uint16 floatOnlyBps, uint8 takeOutAt) internal {
        uint16[2] memory floats = [uint16(2000), 1000];
        uint24[3] memory fees = [uint24(100), 500, 3000];
        for (uint256 j; j < floats.length; ++j) {
            lentBps = floats[j];
            for (uint256 i; i < fees.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                Run memory r = Run(declared, floatOnlyBps, fees[i], 0, 0);
                (int256 worst, int256 end) = _roundsStanding(r, ROUNDS, takeOutAt);
                console2.log(
                    string.concat(
                        _labelStanding(r, takeOutAt),
                        ": worst cumulative LP loss (bps of the smaller edge) ",
                        vm.toString(worst),
                        ", after 288 rounds ",
                        vm.toString(end)
                    )
                );
                assertLe(
                    worst,
                    BAR,
                    string.concat(_labelStanding(r, takeOutAt), ": the LPs lost past a quarter of the edge depth")
                );
                vm.revertToStateAndDelete(snapshot);
            }
        }
        lentBps = 2000;
    }

    /// @dev The property with the fair price resting at each of `fairs` (basis points of the anchor).
    function _holdsStandingOffAnchor(uint24 declared, uint256[2] memory fairs, uint8 takeOutAt) internal {
        for (uint256 j; j < fairs.length; ++j) {
            fairBps = fairs[j];
            _holdsStanding(declared, EQUAL, takeOutAt);
        }
        fairBps = 10_000;
    }
}

/// @notice frxUSD/USDG pegged (`PEG_BPS` 0.5%), as `RehypoRepeatPeggedPair`: both sources centre a +-0.5% band on
/// frxUSD's signed price each keeper pass and open their whole float inside the band.
abstract contract StandingPeggedPair is StandingBase {
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

    function _peg() internal pure virtual override returns (uint16) {
        return PEG;
    }

    function _seed() internal pure override returns (uint256, uint256) {
        return (100_000e18, 100_000e6);
    }

    function _centre() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8, 1 << 192, 1e8 * 1e12)));
    }

    /// @dev 0.48% off the centre, inside the +-0.5% band.
    function _edgePrice(bool below) internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8 * (below ? 9952 : 10_048), 1 << 192, 1e8 * 1e4 * 1e12)));
    }

    function _moveData() internal view override returns (bytes memory) {
        return abi.encodeCall(StandingPosition.rebalanceAt, (abi.encode(price8, block.timestamp)));
    }

    function _fair() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(price8 * fairBps, 1 << 192, 1e8 * 1e4 * 1e12)));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, price8 * fairBps, 1e8 * 1e4) + a1 * 1e12);
    }
}

/// @notice NVDA/USDG at $180, as `RehypoRepeatPricedPair`, with the band a setting: both sources priced with a band of
/// `bandBps` either side of an honest signed report each keeper pass.
abstract contract StandingPricedPair is StandingBase {
    address internal constant NVDA = 0x1000000000000000000000000000000000000001;
    address internal constant USDG = 0x2000000000000000000000000000000000000002;
    /// @dev $180, eight decimals.
    uint256 internal constant PRICE = 180e8;
    /// @dev `GageRehypoSource`'s constants the cap-free width follows from.
    uint256 internal constant PAST_BAND_BPS = 100;
    uint256 internal constant CONCENTRATION_TICKS = 40_003;

    SignedPriceStandIn internal prices;
    uint160 internal par;
    /// @dev Both sources' band either side of the signed price.
    uint16 internal bandBps = 100;

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

    /// @dev About $100,000 a side.
    function _seed() internal pure override returns (uint256, uint256) {
        return (555e18, 100_000e6);
    }

    function _centre() internal view override returns (uint160) {
        return par;
    }

    /// @dev 95% of the band off the centre, inside it.
    function _edgePrice(bool below) internal view override returns (uint160) {
        uint256 off = uint256(bandBps) * 95;
        return uint160(Math.mulDiv(par, Math.sqrt((below ? 1e6 - off : 1e6 + off) * 1e12), 1e9));
    }

    function _moveData() internal view override returns (bytes memory) {
        return abi.encodeCall(StandingPosition.rebalanceAt, (abi.encode(PRICE, block.timestamp)));
    }

    /// @dev The venue's fair price, `fairBps` of the signed price the keeper centres on each pass.
    function _fair() internal view override returns (uint160) {
        return uint160(Math.mulDiv(par, Math.sqrt(fairBps * 1e14), 1e9));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, PRICE * 1e6 * fairBps, 1e26 * 1e4) + a1) * 1e12;
    }

    /// @dev The narrowest declared range at which a priced source's cap inside a band of `band` either side opens its
    /// whole float target (`GageRehypoSource._inBandCap`): the least `R` with `PAST_BAND_BPS * R * C >= 16 * w^2 *
    /// (R + C)`, `w` the band's width in ticks as the source counts it.
    function _capFreeTicks(uint16 band) internal pure returns (uint24) {
        uint256 lo = Math.sqrt(Math.mulDiv(10_000 - band, 1 << 192, 10_000));
        uint256 hi = Math.sqrt(Math.mulDiv(10_000 + band, 1 << 192, 10_000));
        uint256 w = Math.mulDiv(hi - lo, 20_001, lo) + 1;
        uint256 need = 16 * w * w;
        uint256 have = PAST_BAND_BPS * CONCENTRATION_TICKS;
        return uint24(Math.mulDiv(need, CONCENTRATION_TICKS, have - need, Math.Rounding.Ceil));
    }
}

/// @notice frxUSD/USDG stable on the full range, the keeper's +-0.5% band around parity: the pair the hook's stable
/// keeper entry (`rebalance`) is shown on. A stable source declared narrower caps its swap float inside the band,
/// which a standing position is not proven on.
abstract contract StandingStablePair is StandingBase {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRX = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
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

    function _edgePrice(bool below) internal pure override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(below ? 9952 : 10_048, 1 << 192, 1e4 * 1e12)));
    }

    function _moveData() internal view override returns (bytes memory) {
        return abi.encodeCall(StandingPosition.rebalance, (bandLo, bandHi));
    }

    function _fair() internal view override returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(fairBps, 1 << 192, 1e4 * 1e12)));
    }

    function _value(uint256 a0, uint256 a1) internal view override returns (int256) {
        return int256(Math.mulDiv(a0, fairBps, 1e4) + a1 * 1e12);
    }
}

/// @notice An account that opens a PoolManager unlock of its own and makes one call from inside it.
contract Unlocker is IUnlockCallback {
    IPoolManager internal immutable MANAGER;

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function callInsideUnlock(address target, bytes calldata data) external {
        MANAGER.unlock(abi.encode(target, data));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory reason) = target.call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        return "";
    }
}
