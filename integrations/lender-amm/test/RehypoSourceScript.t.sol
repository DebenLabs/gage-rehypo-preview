// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    RehypoSource,
    IGageRehypoSource,
    IGageRehypoSourceFactory,
    RehypoSourceSettings
} from "../script/RehypoSource.s.sol";
import {SignedPriceStandIn} from "./RehypoSourcePricedPlug.t.sol";
import {StablePriceStandIn} from "./RehypoSourceRepeat.t.sol";
import {FailsafeUnlockCheckedHook} from "../src/FailsafeUnlockCheckedHook.sol";
import {FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {FeeModuleStandIn} from "./mocks/FeeModuleStandIn.sol";

/// @dev What the kit's fee hooks show of their rule.
interface IFeeHookRule {
    function swapFee(bool zeroForOne) external view returns (uint24);
    function FEE_FLOOR() external view returns (uint24);
    function FEE_CAP() external view returns (uint24);
    function FEE_MODULE() external view returns (address);
    function FEE_POOL_ID() external view returns (bytes32);
}

/// @notice The rehypo source script (`script/RehypoSource.s.sol`) on a local PoolManager: the release step that
/// deploys the factory on the generation deployer, then the partner's set-up the testnet rehearsal runs, with the
/// plug test's stand-ins for the gage vault and the generation deployer's record. The test contract is the partner.
contract RehypoSourceScriptTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev The example band of gage's keeper: frxUSD (18 decimals, currency0) against USDG (6) at 0.995 to
    /// 1.005.
    uint160 internal constant MIN_BAND = 79_029_843_899_059_723_247_256;
    uint160 internal constant MAX_BAND = 79_425_985_949_584_624_389_260;
    /// @dev One frxUSD for one USDG: a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;

    MockERC20 internal frx;
    MockERC20 internal usdg;
    MockGageVault internal usdgVault;
    FactoryRegistryStandIn internal registry;
    RehypoSource internal script;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();
        frx = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), address(frx));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        usdgVault = new MockGageVault(IERC20(address(usdg)));
        registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        script = new RehypoSource();
        frx.mint(address(this), 1_000_000e18);
        usdg.mint(address(this), 1_000_000e6);
    }

    function _pool(IGageRehypoSourceFactory factory) internal view returns (RehypoSource.Pool memory) {
        return RehypoSource.Pool({
            factory: factory,
            lend: IERC20(address(usdg)),
            vault: address(usdgVault),
            floatBps: 2000,
            floatOnly: IERC20(address(frx)),
            keeper: keeper,
            seedLend: SEED_USDG,
            seedFloat: SEED_FRX,
            salt: "rehearsal",
            settings: RehypoSourceSettings(0, address(0), address(0), 0, 0),
            price8: 1e8,
            failsafeBps: 0,
            pegBps: 0
        });
    }

    function _factory() internal returns (IGageRehypoSourceFactory) {
        return IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(0)));
    }

    // ------------------------------------------------ the release step

    function test_theDeployStepBuildsTheFactoryOnTheGenerationDeployer() public {
        IGageRehypoSourceFactory factory = _factory();
        assertEq(address(factory.POOL_MANAGER()), address(manager));
        assertEq(factory.REGISTRY(), address(registry));
    }

    /// @dev A priced source centres only on the factory's own price source; a factory names it once, at deploy, and the
    /// step refuses an address that does not answer `USDG()`.
    function test_theDeployStepNamesOnePriceSource() public {
        SignedPriceStandIn prices = new SignedPriceStandIn(address(usdg));
        IGageRehypoSourceFactory factory =
            IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(prices)));
        assertEq(factory.PRICE_SOURCE(), address(prices));
        assertEq(_factory().PRICE_SOURCE(), address(0), "stable sources only");
        vm.expectRevert(bytes("PRICE_SOURCE does not answer USDG: not a Nuntius price source"));
        script.deployFactory(manager, address(registry), address(registry));
    }

    /// @dev The factory keeps its registry for good: an address that does not answer `isFactory` (here a vault, which
    /// has code) is refused before anything is deployed.
    function test_theDeployStepRefusesARegistryThatIsNotTheGenerationDeployer() public {
        vm.expectRevert(bytes("GENERATION_DEPLOYER does not answer isFactory: not the generation deployer"));
        script.deployFactory(manager, address(usdgVault), address(0));
    }

    // ------------------------------------------------ the partner's set-up (the rehearsal)

    function test_theRehearsalSetsThePoolUpAsTheRunbookLists() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));

        // The two sources: USDG lent through the gage vault, frxUSD float-only, both bound to the hook.
        assertEq(p.lendSource.vault(), address(usdgVault));
        assertEq(p.floatSource.vault(), address(0));
        assertEq(p.lendSource.depositor(), address(p.hook));
        assertEq(p.floatSource.depositor(), address(p.hook));
        assertTrue(p.lendSource.isKeeper(keeper), "the keeper may rebalance the lent side");
        assertTrue(p.floatSource.isKeeper(keeper), "and the float-only side, since the 8 November generation");

        // The pool: frxUSD (the lower address) first, at one whole unit for one whole unit, seeded through the hook.
        assertEq(Currency.unwrap(p.key.currency0), address(frx));
        assertEq(Currency.unwrap(p.key.currency1), address(usdg));
        assertEq(address(p.key.hooks), address(p.hook));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, PAR);
        assertEq(p.hook.balanceOf(address(this)), 100_000e12, "sqrt(seed0 x seed1) shares to the partner");
        assertEq(PoolId.unwrap(p.hook.getPoolKey().toId()), PoolId.unwrap(p.key.toId()), "the hook took this pool");
    }

    function test_theKeeperEntryCarriesTheHalfPercentBand() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));
        (uint160 lo, uint160 hi) = script.band(p.key);
        assertEq(lo, MIN_BAND);
        assertEq(hi, MAX_BAND);

        string memory json = script.keeperFile(p);
        assertEq(
            json,
            string.concat(
                '{ "schemaVersion": 1, "chainId": ',
                vm.toString(block.chainid),
                ', "sources": [ { "name": "frxUSD/USDG, USDG side", "source": "',
                vm.toString(address(p.lendSource)),
                '", "minSqrtPriceX96": "79029843899059723247256", "maxSqrtPriceX96": "79425985949584624389260" }, ',
                '{ "name": "frxUSD/USDG, frxUSD side", "source": "',
                vm.toString(address(p.floatSource)),
                '", "minSqrtPriceX96": "79029843899059723247256", "maxSqrtPriceX96": "79425985949584624389260" } ] }'
            )
        );
        assertEq(vm.parseJsonAddress(json, ".sources[0].source"), address(p.lendSource), "valid JSON");
        assertEq(vm.parseJsonAddress(json, ".sources[1].source"), address(p.floatSource));
    }

    /// @dev The priced set-up: an X/USDG pool at the signed price, both sources priced on the given price source, the
    /// keeper on both, and keeper entries without a band.
    function test_thePricedRehearsalStartsAtTheSignedPriceAndCarriesNoBand() public {
        SignedPriceStandIn prices = new SignedPriceStandIn(address(usdg));
        RehypoSource.Pool memory pool =
            _pool(IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(prices))));
        pool.settings = RehypoSourceSettings(0, address(prices), address(frx), 100, 500);
        pool.price8 = 18_758_137_450;
        pool.salt = "priced";
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(p.key.toId());
        // frx is currency0: USDG raw per frx raw = 187.58 x 1e6 / 1e18.
        assertEq(sqrtPriceX96, uint160(Math.sqrt(Math.mulDiv(18_758_137_450 * 1e6, 1 << 192, 1e8 * 1e18))));
        assertTrue(p.floatSource.isKeeper(keeper));
        assertEq(p.floatSource.PRICED_TOKEN(), address(frx));
        string memory json = script.keeperFile(p);
        assertEq(
            json,
            string.concat(
                '{ "schemaVersion": 1, "chainId": ',
                vm.toString(block.chainid),
                ', "sources": [ { "name": "frxUSD/USDG, USDG side", "source": "',
                vm.toString(address(p.lendSource)),
                '" }, { "name": "frxUSD/USDG, frxUSD side", "source": "',
                vm.toString(address(p.floatSource)),
                '" } ] }'
            )
        );
    }

    /// @dev What the keeper then does with the entry, and swaps on the result: the set-up is a working pool.
    function test_theKeeperRebalancesInsideTheBandAndSwapsRun() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));
        vm.prank(keeper);
        p.lendSource.rebalance(MIN_BAND, MAX_BAND);
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5, "80% of the USDG lent, 20% kept as float");

        frx.approve(address(swapRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        swap(p.key, true, -1000e18, ZERO_BYTES);
        assertGt(usdg.balanceOf(address(this)) - usdgBefore, 900e6, "a 1,000 frxUSD sale against a 20,000 USDG float");
        uint256 frxBefore = frx.balanceOf(address(this));
        swap(p.key, false, -500e6, ZERO_BYTES);
        assertGt(frx.balanceOf(address(this)) - frxBefore, 490e18);
    }

    /// @dev With `failsafeBps`, the lent source carries the vault failsafe (design 2.5), the float-only one none, and the
    /// hook is the one that asks for it: a swap of more than half the USDG float draws on the vault; without, none does.
    function test_withTheFailsafeTheLentSourceHasItAndTheHookAsksForIt() public {
        IGageRehypoSourceFactory factory = _factory();
        RehypoSource.Pool memory pool = _pool(factory);
        pool.failsafeBps = 1000;
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.lendSource.FAILSAFE_BPS(), 1000, "the lent source has the failsafe");
        assertEq(p.floatSource.FAILSAFE_BPS(), 0, "the float-only source, which has no vault, none");

        vm.prank(keeper);
        p.lendSource.rebalance(MIN_BAND, MAX_BAND);
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5, "the keeper's rebalance lent 80%");
        frx.approve(address(swapRouter), type(uint256).max);
        // 15,000 USDG out of a 20,000 float: the hook asks for 10,000, all of the 10% the source may draw.
        swap(p.key, true, int256(15_000e6), ZERO_BYTES);
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5 - SEED_USDG / 10, "the source drew 10% of its backing");

        // The same pool and swap without the failsafe: the vault is not touched.
        pool.failsafeBps = 0;
        pool.salt = "no failsafe";
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        RehypoSource.Plugged memory q = script.setUpPool(pool);
        assertEq(q.lendSource.FAILSAFE_BPS(), 0);
        vm.prank(keeper);
        q.lendSource.rebalance(MIN_BAND, MAX_BAND);
        swap(q.key, true, int256(15_000e6), ZERO_BYTES);
        assertEq(MockGageVault(pool.vault).cash(), SEED_USDG * 4 / 5, "no vault call without the failsafe");
    }

    /// @dev With a fee rule the pool is a dynamic-fee pool on the kit's fee hook, built as the kit builds it: a swap pays
    /// what the rule's module quotes for its direction; the failsafe form when the lent source has the failsafe; and a
    /// rule on sources that declare no range is refused, the fee hooks being anchored hooks.
    function test_withAFeeRuleThePoolIsDynamicAndSwapsPayTheModulesQuote() public {
        FeeModuleStandIn module = new FeeModuleStandIn();
        bytes32 venuePool = keccak256("the venue's pool for the pair");
        module.set(venuePool, 700, 900);
        RehypoSource.FeeRule memory rule = RehypoSource.FeeRule(address(module), PoolId.wrap(venuePool), 100, 10_000);
        RehypoSource.Pool memory pool = _pool(_factory());
        pool.settings.rangeTicks = 100;
        pool.salt = "fee rule";
        RehypoSource.Plugged memory p = script.setUpPool(pool, rule);

        assertEq(p.key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "a dynamic-fee pool");
        assertEq(
            address(p.hook).code.length,
            vm.getDeployedCode("AnchoredFeeHook.sol:AnchoredFeeHook").length,
            "the kit's fee hook"
        );
        IFeeHookRule hook = IFeeHookRule(address(p.hook));
        assertEq(hook.FEE_MODULE(), address(module));
        assertEq(hook.FEE_POOL_ID(), venuePool);
        assertEq(hook.FEE_FLOOR(), 100);
        assertEq(hook.FEE_CAP(), 10_000);
        assertEq(hook.swapFee(true), 700);
        assertEq(hook.swapFee(false), 900);

        // 100 frxUSD at 0.07%: 99.93 USDG less what the price moves.
        frx.approve(address(swapRouter), type(uint256).max);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        swap(p.key, true, -100e18, ZERO_BYTES);
        uint256 got = usdg.balanceOf(address(this)) - usdgBefore;
        assertLe(got, 99_930_000, "the swap paid the module's fee");
        assertGt(got, 99_800_000);

        pool.failsafeBps = 1000;
        pool.salt = "fee rule, failsafe";
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        RehypoSource.Plugged memory q = script.setUpPool(pool, rule);
        assertEq(
            address(q.hook).code.length,
            vm.getDeployedCode("AnchoredFeeHook.sol:AnchoredFailsafeFeeHook").length,
            "the failsafe fee hook when the lent source has the failsafe"
        );
        assertEq(IFeeHookRule(address(q.hook)).swapFee(false), 900);

        pool.settings.rangeTicks = 0;
        pool.salt = "fee rule, full range";
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        vm.expectRevert(
            bytes("a fee rule needs both sources to declare a range: the kit's fee hooks are anchored hooks")
        );
        script.setUpPool(pool, rule);
    }

    /// @dev The float-only source's address follows from the broadcaster, its token and the salt alone, so a second run
    /// reusing it would meet its own CREATE2 address: the script says which setting to change.
    function test_aSecondRunNeedsAnotherSalt() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        script.setUpPool(pool);
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        vm.expectRevert(bytes("a source already exists at this address: set another REHYPO_SALT"));
        script.setUpPool(pool);

        pool.salt = "second";
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.lendSource.vault(), pool.vault);
    }

    function test_theRehearsalNeverRunsOnMainnet() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        vm.chainId(4663);
        vm.expectRevert(bytes("the rehearsal never runs on chain 4663: there the partner's Safe makes these calls"));
        script.setUpPool(pool);
    }

    // ------------------------------------------------ a declared range (docs/rehypo-source.md, item 6)

    /// @dev Sources declaring a range take equal float targets: the float-only side the lent side's, so neither side is
    /// deeper at the anchor than the other. On the full range the float-only side keeps all its backing as float.
    function test_aDeclaredPoolTakesEqualFloatTargets() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        pool.settings.rangeTicks = 20;
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.lendSource.floatBps(), 2000);
        assertEq(p.floatSource.floatBps(), 2000, "the float-only side takes the lent side's target");

        pool.settings.rangeTicks = 0;
        pool.salt = "full range";
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        RehypoSource.Plugged memory q = script.setUpPool(pool);
        assertEq(q.floatSource.floatBps(), 10_000, "on the full range, all of it");
    }

    /// @dev A declared stable pool makes its first keeper move on a hundredth of the seed, then adds the rest: from the
    /// set-up on, each source has a cap inside the band and the anchored hook holds its range. The partner was a keeper
    /// only for that move; gage's keeper stays.
    function test_aDeclaredStablePoolMakesItsFirstMoveBeforeTheRestOfTheSeed() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        pool.settings.rangeTicks = 20;
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertGt(p.lendSource.swapCap(), 0, "the lent side has a cap from its first move");
        assertGt(p.floatSource.swapCap(), 0, "and the float-only side");
        assertFalse(p.lendSource.isKeeper(address(this)), "the partner kept no keeper role");
        assertFalse(p.floatSource.isKeeper(address(this)));
        assertTrue(p.lendSource.isKeeper(keeper), "gage's keeper rebalances it from here");
        int24 parity = AnchoredRangeReads(address(p.hook)).PARITY_TICK();
        assertEq(p.hook.getTickLower(), parity - 10, "the anchored range holds from the set-up on");
        assertEq(p.hook.getTickUpper(), parity + 10);
        // What the partner put in, all of it: the first hundredth and the rest.
        uint256 usdgIn = p.lendSource.convertToAssets(p.lendSource.balanceOf(address(p.hook)));
        uint256 frxIn = p.floatSource.convertToAssets(p.floatSource.balanceOf(address(p.hook)));
        assertApproxEqRel(usdgIn, SEED_USDG, 1e12, "the whole USDG seed");
        assertApproxEqRel(frxIn, SEED_FRX, 1e12, "the whole frxUSD seed");
        assertLe(usdgIn, SEED_USDG);
        assertLe(frxIn, SEED_FRX);
    }

    /// @dev When the partner is gage's keeper itself (the testnet deploy), the first move leaves its keeper role alone.
    function test_aPartnerThatIsTheKeeperKeepsItsRole() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        pool.settings.rangeTicks = 20;
        pool.keeper = address(this);
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertTrue(p.lendSource.isKeeper(address(this)));
        assertTrue(p.floatSource.isKeeper(address(this)));
    }

    /// @dev A declared priced pool makes no move in the set-up (its first centre needs a signed report, the keeper's):
    /// the anchored hook holds the full range until both sources have moved.
    function test_aDeclaredPricedPoolStaysOnTheFullRangeUntilItsFirstCentre() public {
        SignedPriceStandIn prices = new SignedPriceStandIn(address(usdg));
        RehypoSource.Pool memory pool =
            _pool(IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(prices))));
        pool.settings = RehypoSourceSettings(200, address(prices), address(frx), 100, 500);
        pool.price8 = 18_758_137_450;
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.floatSource.floatBps(), 2000, "equal float targets");
        assertEq(p.lendSource.swapCap(), 0, "no move yet");
        assertEq(p.hook.getTickLower(), -887_272, "the full range");
        assertEq(p.hook.getTickUpper(), 887_272);
        assertEq(p.hook.balanceOf(address(this)), Math.sqrt(SEED_FRX * SEED_USDG), "the whole seed in one deposit");
    }

    /// @dev A pegged pool: both sources priced on frxUSD and pegged, equal float targets at 10%, on the anchored
    /// failsafe hook with its draw economics: ten cents a draw in each token at the starting price, and 10 pips. The full
    /// range until the keeper's first centre, as any declared priced pool.
    function test_aPeggedPoolTakesItsPegAndTheFailsafesDrawEconomics() public {
        StablePriceStandIn prices = new StablePriceStandIn(address(usdg));
        RehypoSource.Pool memory pool =
            _pool(IGageRehypoSourceFactory(script.deployFactory(manager, address(registry), address(prices))));
        pool.settings = RehypoSourceSettings(20, address(prices), address(frx), 50, 100);
        pool.floatBps = 1000;
        pool.failsafeBps = 1000;
        pool.pegBps = 50;
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.lendSource.PEG_BPS(), 50, "the lent source is pegged");
        assertEq(p.floatSource.PEG_BPS(), 50, "and the float-only one");
        assertEq(p.floatSource.floatBps(), 1000, "equal float targets");
        assertEq(p.lendSource.FAILSAFE_BPS(), 1000, "the lent source may draw on its vault's free cash");
        assertEq(p.floatSource.FAILSAFE_BPS(), 1000, "and the float-only one on the float it keeps closed");
        FailsafeUnlockCheckedHook hook = FailsafeUnlockCheckedHook(payable(address(p.hook)));
        // frxUSD is currency0 (18 decimals), USDG currency1 (6): ten cents of each.
        assertEq(hook.MIN_DRAW_FEE_0(), 1e17);
        assertEq(hook.MIN_DRAW_FEE_1(), 1e5);
        assertEq(hook.FORGONE_PIPS(), 10);
        assertEq(p.lendSource.swapCap(), 0, "no move yet: the full range");
        assertEq(p.hook.getTickLower(), -887_272);
    }

    /// @dev Every bounded environment value the rehearsals read is refused outside the source's own bounds rather than
    /// cut to its type: a range of 2^24 ticks no longer deploys the full range, nor 2^24 + 20 a 20-tick one.
    function test_environmentValuesOutsideTheirBoundsAreRefused() public {
        string[6] memory names = ["REHYPO_FACTORY", "LEND_TOKEN", "LEND_VAULT", "FLOAT_TOKEN", "KEEPER", "PRICE_SOURCE"];
        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], vm.toString(address(uint160(0x1000 + i))));
        }
        vm.setEnv("SEED_LEND", "1");
        vm.setEnv("SEED_FLOAT", "1");
        vm.setEnv("PRICE_8", "1");
        _refuses("RANGE_TICKS", "16777216", "RANGE_TICKS must be from 0 to 1774544", false);
        _refuses("RANGE_TICKS", "16777236", "RANGE_TICKS must be from 0 to 1774544", false);
        _refuses("RANGE_TICKS", "1774545", "RANGE_TICKS must be from 0 to 1774544", true);
        vm.setEnv("RANGE_TICKS", "20");
        _refuses("LEND_FLOAT_BPS", "67536", "LEND_FLOAT_BPS must be from 100 to 10000", false);
        _refuses("LEND_FLOAT_BPS", "99", "LEND_FLOAT_BPS must be from 100 to 10000", false);
        vm.setEnv("LEND_FLOAT_BPS", "2000");
        _refuses("FAILSAFE_BPS", "65536", "FAILSAFE_BPS must be from 0 to 1000", false);
        _refuses("FAILSAFE_BPS", "1001", "FAILSAFE_BPS must be from 0 to 1000", true);
        vm.setEnv("FAILSAFE_BPS", "0");
        _refuses("PRICED_BAND_BPS", "65636", "PRICED_BAND_BPS must be from 10 to 300", true);
        _refuses("PRICED_BAND_BPS", "9", "PRICED_BAND_BPS must be from 10 to 300", true);
        vm.setEnv("PRICED_BAND_BPS", "100");
        _refuses("PRICED_MOVE_BPS", "0", "PRICED_MOVE_BPS must be from 1 to 1000", true);
        _refuses("PRICED_MOVE_BPS", "66536", "PRICED_MOVE_BPS must be from 1 to 1000", true);
    }

    function _refuses(string memory name, string memory value, string memory message, bool priced) internal {
        vm.setEnv(name, value);
        vm.expectRevert(bytes(string.concat(message, ": refused, not cut to fit")));
        if (priced) script.rehearsePriced();
        else script.rehearse();
    }
}

interface AnchoredRangeReads {
    function PARITY_TICK() external view returns (int24);
}
