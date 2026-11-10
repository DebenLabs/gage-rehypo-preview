// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ReHypothecationERC4626Mock} from "@openzeppelin/uniswap-hooks/src/mocks/general/ReHypothecationERC4626Mock.sol";
import {
    RehypoSourcePlugTest,
    IGageRehypoSource,
    IGageRehypoSourceFactory,
    FactoryRegistryStandIn
} from "./RehypoSourcePlug.t.sol";
import {RehypoSourceSettings} from "../script/RehypoSource.s.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {KitBands} from "./utils/KitBands.sol";
// Imported so the tests can deploy it by name (`deployCodeTo`).
import {FailsafeReHypothecationMock} from "./mocks/RangedReHypothecationMocks.sol";

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

interface IFailsafeSource {
    function FAILSAFE_BPS() external view returns (uint16);
}

/// @notice The whole plug suite again with the vault failsafe (2.5) on both sources, 10% of the backing. OpenZeppelin's
/// unmodified hook never asks for it, so every test passes unchanged: no swap calls the vault, and every number is the
/// same as with the failsafe off.
contract RehypoSourcePlugFailsafeOnTest is RehypoSourcePlugTest {
    function setUp() public virtual override {
        _sources();
        _plug(address(FLAGS | (uint160(0x5555) << 144)), "ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock");
    }

    /// @dev The parent's tokens, vault and factory, and both sources with the failsafe on.
    function _sources() internal {
        deployFreshManagerAndRouters();
        frx = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), address(frx));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        usdgVault = new MockGageVault(IERC20(address(usdg)));
        registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        factory = IGageRehypoSourceFactory(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(manager), address(registry), address(0)))
        );
        RehypoSourceSettings memory stable;
        IGageRehypoSourceFactoryFailsafe f = IGageRehypoSourceFactoryFailsafe(address(factory));
        vm.startPrank(partner);
        frxSource = IGageRehypoSource(
            f.create(IERC20(address(frx)), address(0), partner, partner, 10_000, stable, 1000, "frx")
        );
        usdgSource = IGageRehypoSource(
            f.create(IERC20(address(usdg)), address(usdgVault), partner, partner, 2000, stable, 1000, "usdg")
        );
        vm.stopPrank();
        assertEq(IFailsafeSource(address(usdgSource)).FAILSAFE_BPS(), 1000, "the failsafe is on");
    }

    /// @dev The rest of the parent's set-up: the hook, the pool, the bindings, the holders, the seed, the keeper's pass.
    function _plug(address at, string memory hookArtifact) internal {
        _plug(at, hookArtifact, "");
    }

    /// @dev The same with `extra` after the hook's constructor arguments (the kit's failsafe hook's draw economics).
    function _plug(address at, string memory hookArtifact, bytes memory extra) internal {
        deployCodeTo(
            hookArtifact, bytes.concat(abi.encode(address(manager), address(frxSource), address(usdgSource)), extra), at
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
}

/// @notice The failsafe on a hook that asks for it (`FailsafeReHypothecationMock`): a swap the float can fill makes no
/// vault call; a larger one draws from the USDG source's own free cash and is filled at a better price than the float
/// alone gives; a refused draw leaves the swap to the float; past the band it draws nothing.
contract RehypoSourceFailsafeHookTest is RehypoSourcePlugFailsafeOnTest {
    function setUp() public virtual override {
        _sources();
        _plug(address(FLAGS | (uint160(0x6565) << 144)), "RangedReHypothecationMocks.sol:FailsafeReHypothecationMock");
    }

    /// @return paid The frxUSD the trader paid for exactly `amount` USDG.
    function _buyUsdg(uint256 amount) internal returns (uint256 paid) {
        uint256 frxBefore = frx.balanceOf(trader);
        uint256 usdgBefore = usdg.balanceOf(trader);
        vm.prank(trader, trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(usdg.balanceOf(trader) - usdgBefore, amount, "the exact output");
        paid = frxBefore - frx.balanceOf(trader);
    }

    function test_failsafe_aSwapTheFloatCanFillMakesNoVaultCall() public {
        uint256 calls = usdgVault.calls();
        usdgVault.setOffline(true);
        _buyUsdg(5000e6);
        usdgVault.setOffline(false);
        assertEq(usdgVault.calls(), calls, "no vault call");
    }

    function test_failsafe_aLargerSwapDrawsAndPaysLessThanOnTheFloatAlone() public {
        uint256 snapshot = vm.snapshotState();
        usdgVault.setRewardsPending(true);
        uint256 calls = usdgVault.calls();
        uint256 floatAlone = _buyUsdg(15_000e6);
        assertEq(usdgVault.calls(), calls, "a refused draw changes nothing: no withdrawal went through");
        vm.revertToStateAndDelete(snapshot);

        calls = usdgVault.calls();
        uint256 withDraw = _buyUsdg(15_000e6);
        assertEq(usdgVault.calls(), calls + 1, "one vault withdrawal");
        assertLt(withDraw, floatAlone, "the drawn depth fills it at a better price");
        emit log_named_decimal_uint("frxUSD paid on the float alone", floatAlone, 18);
        emit log_named_decimal_uint("frxUSD paid with the failsafe", withDraw, 18);
    }

    function test_failsafe_pastTheBandItDrawsNothing() public {
        (uint160 lo, uint160 hi) = KitBands.to(PAR - 1);
        vm.prank(keeper);
        usdgSource.rebalance(lo, hi);
        uint256 calls = usdgVault.calls();
        _buyUsdg(15_000e6);
        assertEq(usdgVault.calls(), calls, "past the band the cap stays in charge");
    }
}
