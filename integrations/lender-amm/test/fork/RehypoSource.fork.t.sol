// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {UnlockCheckedHook} from "../../src/UnlockCheckedHook.sol";
import {RehypoSource} from "../../script/RehypoSource.s.sol";
import {IGageRehypoSourceFactory, IGageRehypoSource, FactoryRegistryStandIn} from "../RehypoSourcePlug.t.sol";
import {MockGageVault} from "../mocks/MockGageVault.sol";

/// @notice gage's rehypo source on Robinhood Chain mainnet's own state (chain 4663): the live Uniswap v4
/// PoolManager, real USDG and frxUSD (`deal`t), the factory built in `contracts/` (`forge build
/// src/rehypo/GageRehypoSourceFactory.sol` there first) and the partner's reference hook (`UnlockCheckedHook`) on a new
/// frxUSD/USDG pool at one for one with a static fee, set up in the order `script/RehypoSource.s.sol` `rehearse()` uses.
/// The gage vault is a STAND-IN (`MockGageVault`, the plug test's), and so is the generation deployer's record of
/// factories (`FactoryRegistryStandIn`): neither exists on chain 4663 before the r13 release. Every write is a fork-VM
/// edit; nothing is sent to the chain.
/// @dev Skipped unless `LENDER_AMM_MAINNET_FORK_RPC` is set; `LENDER_AMM_MAINNET_FORK_BLOCK` pins the block, otherwise
/// the head is used.
contract RehypoSourceMainnetForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant MANIFEST = "../../deployments/manifest/4663.json";
    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    /// @dev `contracts/addresses.json` `uniswapV4.PoolManager`, the manifest's `PoolManager`.
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev frxUSD (18 decimals), as `contracts/test/fork/V4StableLend.fork.t.sol` names it: currency0 of the pool.
    address internal constant FRXUSD = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev The script's stable pool: 0.01%, every tick, a static fee.
    uint24 internal constant FEE = 100;
    int24 internal constant TICK_SPACING = 1;
    /// @dev One frxUSD for one USDG: a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;
    uint16 internal constant USDG_FLOAT_BPS = 2000;

    MockGageVault internal usdgVault;
    IGageRehypoSource internal frxSource;
    IGageRehypoSource internal usdgSource;
    UnlockCheckedHook internal hook;
    PoolKey internal key;
    PoolSwapTest internal router;
    uint160 internal lo;
    uint160 internal hi;
    /// @dev What the live PoolManager held of each token before the seed.
    uint256 internal managerFrx;
    uint256 internal managerUsdg;

    address internal partner = makeAddr("partner safe");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");

    function setUp() public {
        string memory rpc = vm.envOr("LENDER_AMM_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("LENDER_AMM_MAINNET_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
        string memory manifest = vm.readFile(MANIFEST);
        assertEq(vm.parseJsonAddress(manifest, ".PoolManager"), address(POOL_MANAGER), "manifest PoolManager");
        assertEq(vm.parseJsonAddress(manifest, ".USDG"), USDG, "manifest USDG");
        assertGt(address(POOL_MANAGER).code.length, 0, "the live PoolManager has code at the fork block");
        assertGt(FRXUSD.code.length, 0, "frxUSD has code at the fork block");
        // frxUSD is in neither the manifest nor `contracts/addresses.json`: the token itself says what it is.
        assertEq(IERC20Metadata(FRXUSD).symbol(), "frxUSD", "frxUSD symbol");
        assertEq(IERC20Metadata(FRXUSD).decimals(), 18, "frxUSD decimals");

        // The stand-ins: a gage vault of real USDG, recorded as its own factory.
        usdgVault = new MockGageVault(IERC20(USDG));
        FactoryRegistryStandIn registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        IGageRehypoSourceFactory factory = IGageRehypoSourceFactory(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(POOL_MANAGER), address(registry), address(0)))
        );

        // `rehearse()`'s order, from the partner: 1. one source per token; 2. the hook naming them in currency order;
        // 3. the pool at one for one; 4. the bindings; 5. the seed; 6. gage's keeper.
        vm.startPrank(partner);
        frxSource = IGageRehypoSource(factory.create(IERC20(FRXUSD), address(0), partner, partner, 10_000, "frx"));
        usdgSource = IGageRehypoSource(
            factory.create(IERC20(USDG), address(usdgVault), partner, partner, USDG_FLOAT_BPS, "usdg")
        );
        vm.stopPrank();
        address at = address(FLAGS | (uint160(0x4663) << 144));
        assertEq(at.code.length, 0, "no contract at the hook's address on chain");
        deployCodeTo(
            "UnlockCheckedHook.sol:UnlockCheckedHook",
            abi.encode(address(POOL_MANAGER), address(frxSource), address(usdgSource)),
            at
        );
        hook = UnlockCheckedHook(payable(at));
        key = PoolKey(Currency.wrap(FRXUSD), Currency.wrap(USDG), FEE, TICK_SPACING, IHooks(at));
        (lo, hi) = new RehypoSource().band(key);
        router = new PoolSwapTest(POOL_MANAGER);

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

        managerFrx = IERC20(FRXUSD).balanceOf(address(POOL_MANAGER));
        managerUsdg = IERC20(USDG).balanceOf(address(POOL_MANAGER));
        vm.startPrank(partner);
        POOL_MANAGER.initialize(key, PAR);
        frxSource.bind(key);
        usdgSource.bind(key);
        hook.seedLiquidity(SEED_FRX, SEED_USDG);
        usdgSource.setKeeper(keeper, true);
        vm.stopPrank();
    }

    /// @dev The rehypo path end to end on the live PoolManager, an LP exit taking the vault's free cash first: the
    /// keeper's first move, swaps on the floats alone, an exit the vault pays, an exit the float pays while the vault
    /// refuses, the swap float drained to zero and reopened by the keeper inside its band, and the keeper's rebalance
    /// past the band, which opens swaps no deeper.
    function test_fork_rehypoPathOnTheLivePoolManager() public {
        // The keeper's first move, inside its band: 80% of the USDG is lent through the vault.
        assertEq(_price(), PAR, "the pool starts at one for one");
        assertTrue(lo < PAR && PAR < hi, "inside the script's band");
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertEq(usdgSource.float(), SEED_USDG / 5, "20% stays in the float");
        assertEq(usdgSource.swapFloat(), SEED_USDG / 5, "all of it open to swaps");
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5, "80% in the vault");
        assertEq(frxSource.float(), SEED_FRX, "frxUSD stays whole in its float");
        assertEq(IERC20(FRXUSD).balanceOf(address(POOL_MANAGER)) - managerFrx, SEED_FRX, "the floats are claims");
        assertEq(IERC20(USDG).balanceOf(address(POOL_MANAGER)) - managerUsdg, SEED_USDG / 5);

        // Swaps both ways with the vault offline: a swap never touches it.
        usdgVault.setOffline(true);
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        _swap(true, -100e18);
        assertGt(IERC20(USDG).balanceOf(trader) - usdgBefore, 99e6, "100 frxUSD sold for USDG");
        uint256 frxBefore = IERC20(FRXUSD).balanceOf(trader);
        _swap(false, -100e6);
        assertGt(IERC20(FRXUSD).balanceOf(trader) - frxBefore, 99e18, "100 USDG sold for frxUSD");
        _swapTo(PAR);
        usdgVault.setOffline(false);

        // An exit the vault pays: a fifth of the pool, as much USDG as the whole float. The vault's free cash pays what
        // the float cannot spare above the swap float's share of what stays.
        uint256 fifth = hook.totalSupply() / 5;
        (uint256 held, uint256 backing, uint256 depth) = _reading();
        (, uint256 out) = hook.previewRedeem(fifth);
        uint256 share = Math.mulDiv(depth, backing - out, backing);
        uint256 cash = usdgVault.cash();
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(fifth, 0, 0);
        assertApproxEqAbs(cash - usdgVault.cash(), out + share - held, 2, "the vault paid its part");
        assertApproxEqAbs(usdgSource.swapFloat(), share, 2, "the swap float keeps its share of what stays");
        _swapBothWays();

        // An exit the float pays: the vault refuses every share change (`RewardsPending`), the float can pay the whole
        // exit, so it does, and swaps go on.
        usdgVault.setRewardsPending(true);
        uint256 onePercent = hook.totalSupply() / 100;
        (held,,) = _reading();
        (, out) = hook.previewRedeem(onePercent);
        cash = usdgVault.cash();
        // The vault is asked for its part and refuses: the float pays instead.
        vm.expectCall(address(usdgVault), abi.encodeWithSelector(MockGageVault.withdraw.selector), 1);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(onePercent, 0, 0);
        assertEq(usdgVault.cash(), cash, "the vault paid nothing");
        assertEq(usdgSource.float(), held - out, "the float paid it all");
        assertGt(usdgSource.swapFloat(), 0);
        _swapBothWays();
        usdgVault.setRewardsPending(false);

        // The freeze that remains (docs/rehypo-source.md, "Limits and risks"): with every USDG of the vault lent, an exit
        // as large as the float takes the whole float and the swap float falls to zero. An LP's entry brings the float back to its target but deepens swaps
        // only by its share of zero: the float alone reads on target, swaps stay stopped inside the band.
        usdgVault.lend(usdgVault.cash());
        (held,,) = _reading();
        uint256 drain = _sharesFor(held);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(drain, 0, 0);
        assertEq(usdgSource.float(), 0, "the float is gone");
        assertEq(usdgSource.swapFloat(), 0, "and swaps with it");
        _swapStopped();
        uint256 quarter = hook.totalSupply() / 4;
        vm.prank(lp);
        hook.addReHypothecatedLiquidity(quarter, type(uint256).max, type(uint256).max);
        (held, backing, depth) = _reading();
        assertApproxEqRel(held, Math.mulDiv(backing, USDG_FLOAT_BPS, 10_000), 1e12, "the float sits on its target");
        assertEq(depth, 0, "the swap float is still zero");
        _swapStopped();
        uint160 price = _price();
        assertTrue(lo <= price && price <= hi, "inside the keeper's band");

        // The keeper reopens it: one rebalance inside the band, nothing to move, sets the swap float to the float.
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        assertEq(usdgSource.float(), held, "nothing moved");
        assertApproxEqAbs(usdgSource.swapFloat(), held, 2, "swaps open again");
        assertGt(usdgSource.swapFloat(), 0);
        _swapBothWays();

        // Past the band the keeper's rebalance goes through and deepens nothing: it leaves the swap float where it was
        // or at 1% of the target, whichever is more, and never above the target.
        uint160 past = hi + hi / 10_000;
        _swapTo(past);
        assertEq(_price(), past, "the price sits just past the band");
        (, backing, depth) = _reading();
        uint256 target = Math.mulDiv(backing, USDG_FLOAT_BPS, 10_000);
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        uint256 bound = Math.max(depth, Math.mulDiv(target, usdgSource.PAST_BAND_BPS(), 10_000));
        assertLe(usdgSource.swapFloat(), bound, "past the band, no deeper");
        assertLe(usdgSource.swapFloat(), target, "nor above the target");
    }

    // ---------------------------------------------------------------- helpers

    bytes4 internal constant NO_USABLE_LIQUIDITY = bytes4(keccak256("NoUsableLiquidity()"));

    /// @dev The USDG source's float, backing and swap float.
    function _reading() internal view returns (uint256 held, uint256 backing, uint256 depth) {
        return (usdgSource.float(), usdgSource.totalAssets(), usdgSource.swapFloat());
    }

    /// @dev What the hook holds in the USDG source, as the hook counts it: its shares at the source's price.
    function _hookUsdg() internal view returns (uint256) {
        return IERC4626(address(usdgSource)).convertToAssets(IERC4626(address(usdgSource)).balanceOf(address(hook)));
    }

    /// @dev The fewest hook shares whose exit takes exactly `usdg` from the USDG source (the hook's own floor rounding).
    function _sharesFor(uint256 usdg) internal view returns (uint256 shares) {
        shares = Math.mulDiv(usdg, hook.totalSupply() + 1e6, _hookUsdg() + 1, Math.Rounding.Ceil);
        (, uint256 out) = hook.previewRedeem(shares);
        assertEq(out, usdg, "the exit takes exactly that");
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
    }

    /// @dev `frxIn`: sell frxUSD for USDG, else USDG for frxUSD; a negative amount is an exact input. A 100 trade moves
    /// a 20,000 USDG float about 1%, past the band: `_swapBothWays` trades back to one for one.
    function _swap(bool frxIn, int256 amountSpecified) internal {
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: frxIn,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: frxIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Small trades both ways, then back to one for one.
    function _swapBothWays() internal {
        _swap(true, -100e18);
        _swap(false, -100e6);
        _swapTo(PAR);
    }

    /// @dev Trade the price to `limit`.
    function _swapTo(uint160 limit) internal {
        uint160 price = _price();
        if (price == limit) return;
        bool zeroForOne = limit < price;
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: zeroForOne ? -int256(500_000e18) : -int256(500_000e6),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev OpenZeppelin's hook sizes a swap's liquidity from the smaller side: with no USDG swap float, every swap
    /// reverts `NoUsableLiquidity` in its `beforeSwap`, both ways.
    function _swapStopped() internal {
        bytes memory stopped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NO_USABLE_LIQUIDITY),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.prank(trader);
        vm.expectRevert(stopped);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.prank(trader);
        vm.expectRevert(stopped);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -100e6, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
