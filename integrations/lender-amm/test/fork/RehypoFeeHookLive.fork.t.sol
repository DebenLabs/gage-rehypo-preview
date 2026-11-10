// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RehypoSourceSettings} from "../../script/RehypoSource.s.sol";
import {AnchoredUnlockCheckedHook} from "../../src/AnchoredUnlockCheckedHook.sol";
import {IRehypoFeeSource} from "../../src/AnchoredFeeHook.sol";
import {IRepeatFactory, StablePriceStandIn} from "../RehypoSourceRepeat.t.sol";
import {FeeModuleStandIn} from "../mocks/FeeModuleStandIn.sol";

interface ILiveSource {
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function rebalanceAt(bytes calldata report) external;
    function totalAssets() external view returns (uint256);
    function float() external view returns (uint256);
    function swapFloat() external view returns (uint256);
    function failsafeLeft() external view returns (uint256);
    function claimPockets(uint256[] calldata pocketIds) external;
    function forward(IERC20 token) external;
}

interface ILiveVault {
    function totalAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function cash() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function earliestMaturity() external view returns (uint40);
    function PROTOCOL_SOURCE() external view returns (address);
    function settle(uint256[] calldata ids) external;
    function recover(uint256 id) external;
    function investReserve(uint256 assets, uint256 minShares) external returns (uint256 shares);
    function pocketCount() external view returns (uint256);
    function pockets(uint256 id) external view returns (uint256, address, uint256, uint256, uint256, uint64);
}

/// @dev `GageV2Vault.getLoan`'s record (`V2Loan`), its two enums as their numbers.
struct LiveLoan {
    address originator;
    address account;
    address token;
    address collateralBeneficiary;
    uint8 kind;
    uint8 state;
    uint8 filled;
    uint32 term;
    uint40 fundingDeadline;
    uint40 fundedAt;
    uint40 closedAt;
    uint128 principal;
    uint128 cap;
    uint128 originationFee;
    uint128 borrowerReward;
    uint128 lenderReward;
    uint256 collateral;
    bytes32 exposureKey;
    uint256 exposureAmount;
}

interface ILiveCore {
    function getLoan(uint256 id) external view returns (LiveLoan memory);
    function ownerOf(uint256 id) external view returns (address);
    function reclaim(uint256 id, address recipient) external;
    function finalizeDefault(uint256 id) external;
}

interface IFeeHookLive {
    function swapFee(bool zeroForOne) external view returns (uint24);
}

/// @notice A venue's frxUSD/USDG pool on the kit, on Robinhood Chain mainnet's own state at the head (chain 4663), as
/// far as a fork can take it. LIVE: the Uniswap v4 PoolManager; USDG and frxUSD (`deal`t); gage's generation deployer and
/// its current Intent factory; a gage partner vault (its name is SILICON), its Morpho reserve and its two running loans
/// on gage's lending core, and their borrower; and, when the environment names one (`REHYPO_FEE_MODULE`,
/// `REHYPO_FEE_POOL_ID`), a venue's own fee contract and the pool of its own the kit's fee hook reads each swap's fee
/// for. BUILT HERE, not on the chain: gage's rehypo source factory of this tree (pegged sources), the kit's
/// `AnchoredFailsafeFeeHook`, the pool, and, where the environment names no fee contract, a stand-in quoting 0.05% each
/// way. A STAND-IN: frxUSD's signed price (no feed is chosen for mainnet), held at one dollar. NOT REACHED: a new loan
/// funded from the pool's dollars, which needs a funding plan signed by gage's rates service; the borrowing here is the
/// vault's own running loans, repaid by their real borrower's account and, for the second, left to default. Every
/// write is a fork-VM edit; nothing is sent to the chain.
/// @dev Skipped unless `LENDER_AMM_MAINNET_FORK_RPC` is set. It reads live state at the head, so it is a run to make by
/// hand, not a pinned CI test: written against block 110,716,834 (10 November 2026), where the vault holds loans 1 and
/// 7. Its name keeps it out of the CI job's `RehypoSource*.fork.t.sol`. Run it with `--isolate`: the vault's reserve (a
/// Morpho Vault V2) accrues once per transaction, and without that flag the whole test is one transaction, so the
/// reserve's price stands still after the vault's first deposit and no reserve interest shows.
contract RehypoFeeHookLiveForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FRXUSD = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    /// @dev gage's live manifest for chain 4663: `generationDeployer.address`, `intentV1.factory`, `intentV1.core`.
    address internal constant GENERATION_DEPLOYER = 0xcea38204C97e9745f831978357d562E5CcC6834F;
    address internal constant INTENT_FACTORY = 0xB086944b140758b33694220d4Fe93C9A8D8618a1;
    /// @dev `intentV1.fillRouter`, through which gage's keeper puts a vault's idle cash into its Morpho reserve.
    address internal constant FILL_ROUTER = 0xAE9607acb7e14bD37cB714cFf8f35B30443133c8;
    ILiveCore internal constant CORE = ILiveCore(0x0086EC1540719d4199432797e2b6068E6aE5a0e5);
    /// @dev The partner vault this run lends through (USDG; its name is SILICON), created by `INTENT_FACTORY`.
    ILiveVault internal constant VAULT = ILiveVault(0x6A6aE6DBA685bd0cCbF5572c6222ad61EdA3a04A);
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @dev One frxUSD for one USDG: a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 250_000e18;
    uint256 internal constant SEED_USDG = 250_000e6;
    /// @dev The set-up rehearsed: a 10% float on both sides, and 10% of each side kept for a swap to draw.
    uint16 internal constant FLOAT_BPS = 1000;
    uint16 internal constant FAILSAFE_BPS = 1000;
    uint24 internal constant FEE_FLOOR = 100;
    uint24 internal constant FEE_CAP = 10_000;

    StablePriceStandIn internal prices;
    ILiveSource internal frxSource;
    ILiveSource internal usdgSource;
    AnchoredUnlockCheckedHook internal hook;
    PoolKey internal key;
    PoolSwapTest internal router;
    bool internal forked;

    /// @dev The fee contract the hook reads, and the pool of that contract's own it asks about: a venue's, from
    /// `REHYPO_FEE_MODULE` and `REHYPO_FEE_POOL_ID`, or a stand-in quoting 0.05% each way.
    address internal feeModule;
    bytes32 internal feePool;

    address internal partner = makeAddr("the pool's lp");
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("LENDER_AMM_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("LENDER_AMM_MAINNET_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        forked = true;
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
        string memory manifest = vm.readFile("../../deployments/manifest/4663.json");
        assertEq(vm.parseJsonAddress(manifest, ".generationDeployer.address"), GENERATION_DEPLOYER);
        assertEq(vm.parseJsonAddress(manifest, ".intentV1.factory"), INTENT_FACTORY);
        assertEq(IERC20Metadata(FRXUSD).symbol(), "frxUSD");
        assertEq(VAULT.PROTOCOL_SOURCE(), INTENT_FACTORY, "the vault is the current generation's");
        feeModule = vm.envOr("REHYPO_FEE_MODULE", address(0));
        feePool = vm.envOr("REHYPO_FEE_POOL_ID", bytes32(0));
        if (feeModule == address(0)) {
            FeeModuleStandIn standIn = new FeeModuleStandIn();
            feePool = keccak256("the venue's own pool for the pair");
            standIn.set(feePool, 500, 500);
            feeModule = address(standIn);
        }
        assertGt(feeModule.code.length, 0, "the fee contract is deployed");

        // The stand-in: frxUSD's signed price. The factory is this branch's build, on the live registry.
        prices = new StablePriceStandIn(USDG);
        IRepeatFactory factory = IRepeatFactory(
            deployCode(FACTORY_ARTIFACT, abi.encode(address(POOL_MANAGER), GENERATION_DEPLOYER, address(prices)))
        );
        // Pegged sources on a +-0.5% range and band, the centre moving at most 1% an hour; equal float targets.
        RehypoSourceSettings memory settings = RehypoSourceSettings(100, address(prices), FRXUSD, 50, 100);
        vm.startPrank(partner);
        frxSource = ILiveSource(
            factory.create(IERC20(FRXUSD), address(0), partner, partner, FLOAT_BPS, settings, FAILSAFE_BPS, 50, "frx")
        );
        usdgSource = ILiveSource(
            factory.create(
                IERC20(USDG), address(VAULT), partner, partner, FLOAT_BPS, settings, FAILSAFE_BPS, 50, "usdg"
            )
        );
        vm.stopPrank();

        // The kit's failsafe fee hook, reading the fee contract's quote for its own pool of the pair.
        address at = address(FLAGS | (uint160(0x4663fee) << 144));
        assertEq(at.code.length, 0, "no contract at the hook's address on chain");
        deployCodeTo(
            "AnchoredFeeHook.sol:AnchoredFailsafeFeeHook",
            abi.encode(
                address(POOL_MANAGER),
                address(frxSource),
                address(usdgSource),
                uint256(1e17),
                uint256(1e5),
                uint24(10),
                FEE_FLOOR,
                FEE_CAP,
                feeModule,
                feePool
            ),
            at
        );
        hook = AnchoredUnlockCheckedHook(payable(at));
        key = PoolKey(Currency.wrap(FRXUSD), Currency.wrap(USDG), LPFeeLibrary.DYNAMIC_FEE_FLAG, int24(1), IHooks(at));
        router = new PoolSwapTest(POOL_MANAGER);

        address[2] memory holders = [partner, trader];
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

        vm.startPrank(partner);
        POOL_MANAGER.initialize(key, PAR);
        frxSource.bind(key);
        usdgSource.bind(key);
        frxSource.setKeeper(keeper, true);
        usdgSource.setKeeper(keeper, true);
        hook.seedLiquidity(SEED_FRX, SEED_USDG);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A keeper pass five minutes on: each needs a signed price newer than the last one's.
    function _keeperPass() internal {
        vm.warp(block.timestamp + 5 minutes);
        bytes memory report = abi.encode(uint256(1e8), block.timestamp);
        vm.startPrank(keeper);
        usdgSource.rebalanceAt(report);
        frxSource.rebalanceAt(report);
        vm.stopPrank();
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = POOL_MANAGER.getSlot0(key.toId());
    }

    /// @dev A swap by the trader, and the fee the PoolManager charged it, in pips, from its `Swap` event.
    function _swap(bool zeroForOne, int256 amount, uint160 limit) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(trader, trader);
        router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(key.toId());
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(POOL_MANAGER) && logs[i].topics[0] == SWAP_TOPIC && logs[i].topics[1] == id)
            {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "the swap went through this pool");
    }

    function _vaultValue() internal view returns (uint256) {
        return VAULT.convertToAssets(VAULT.balanceOf(address(usdgSource)));
    }

    function _bounded(uint24 fee) internal pure returns (uint24) {
        return fee < FEE_FLOOR ? FEE_FLOOR : (fee > FEE_CAP ? FEE_CAP : fee);
    }

    // ---------------------------------------------------------------- the rehearsal

    /// @dev Step 3 of the rehearsal, apart for the compiler's stack.
    function _saleThatAsksBothSources() internal {
        // 3. A swap that would move the price past the hook's tolerance on the floats asks both sources: the USDG comes
        // from the vault's free cash inside the swap, the frxUSD from the float its source keeps closed.
        _keeperPass();
        uint256 room = usdgSource.failsafeLeft();
        uint256 roomFrx = frxSource.failsafeLeft();
        uint256 vaultHeld = VAULT.totalAssets();
        // 10% of the lent side's backing, which the two swaps' fees have already added to.
        assertApproxEqAbs(room, SEED_USDG / 10, 1e6, "10% of the lent side may be drawn between two keeper moves");
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        _swap(true, -20_000e18, TickMath.MIN_SQRT_PRICE + 1);
        uint256 drew = room - usdgSource.failsafeLeft();
        assertGt(drew, 10_000e6, "the swap drew on the vault");
        assertApproxEqAbs(vaultHeld - VAULT.totalAssets(), drew, 2, "paid by the vault, inside the swap");
        uint256 opened = roomFrx - frxSource.failsafeLeft();
        assertApproxEqRel(opened / 1e12, drew, 0.01e18, "the frxUSD source opened the same share of its own");
        console2.log("a 20,000 frxUSD sale drew from the vault, USDG:", drew / 1e6);
        console2.log("and opened of the frxUSD its source kept closed:", opened / 1e18);
        console2.log("and paid the trader, USDG:", (IERC20(USDG).balanceOf(trader) - usdgBefore) / 1e6);
        _swap(false, -int256(1e12), PAR);
        assertEq(_price(), PAR, "arbitrage brings the pool back to one for one");
        _keeperPass();
    }

    function test_fork_aPoolOnTheKitLendsThroughALiveVaultWhileItsLoansRepayAndDefault() public {
        if (!forked) return;
        uint256 vaultBefore = VAULT.totalAssets();
        // What the LP holds outside the pool, in raw USDG (frxUSD at one dollar), after seeding 500,000.
        uint256 lpBefore = IERC20(FRXUSD).balanceOf(partner) / 1e12 + IERC20(USDG).balanceOf(partner);
        uint256 paidIn = SEED_FRX / 1e12 + SEED_USDG;

        // 1. The keeper's first move: 10% of each side stays in the pool, 90% of the USDG goes into the vault.
        _keeperPass();
        assertEq(usdgSource.float(), SEED_USDG / 10, "10% of the USDG is the float");
        assertEq(frxSource.swapFloat(), SEED_FRX / 10, "10% of the frxUSD is open to swaps");
        // The vault's own loans and reserve earn during the pass's five minutes: a fraction of a cent on top.
        assertApproxEqAbs(VAULT.totalAssets() - vaultBefore, SEED_USDG * 9 / 10, 1e6, "the vault took 225,000 USDG");
        assertApproxEqAbs(_vaultValue(), SEED_USDG * 9 / 10, 2, "held as vault shares by the USDG source");
        console2.log("the vault before the pool, USDG:", vaultBefore / 1e6);
        console2.log("the vault after the first move, USDG:", VAULT.totalAssets() / 1e6);
        // gage's keeper puts a vault's idle cash into its Morpho reserve (steakUSDG), through the fill router.
        uint256 idle = VAULT.cash();
        vm.prank(FILL_ROUTER);
        try VAULT.investReserve(idle, 0) {
            console2.log("the vault put into its Morpho reserve, USDG:", idle / 1e6);
        } catch {
            console2.log(
                "the Morpho reserve took no deposit at this block: the vault keeps the cash idle, USDG:", idle / 1e6
            );
        }

        // 2. Swaps pay what the fee contract quotes for its own pool of the pair, read at each swap.
        uint24 quote0 = IRehypoFeeSource(feeModule).currentFee(PoolId.wrap(feePool), true);
        uint24 quote1 = IRehypoFeeSource(feeModule).currentFee(PoolId.wrap(feePool), false);
        assertGt(quote0, 0, "the fee contract quotes a fee for selling frxUSD");
        assertGt(quote1, 0, "and for buying it");
        console2.log("the fee contract's quote, pips, each way:", quote0, quote1);
        assertEq(IFeeHookLive(address(hook)).swapFee(true), _bounded(quote0));
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        assertEq(_swap(true, -2000e18, TickMath.MIN_SQRT_PRICE + 1), _bounded(quote0), "the swap paid the quoted fee");
        uint256 got = IERC20(USDG).balanceOf(trader) - usdgBefore;
        assertGt(got, 1990e6, "2,000 frxUSD sold for USDG");
        assertLe(got, 2000e6 * (1e6 - uint256(_bounded(quote0))) / 1e6, "less the fee");
        assertEq(_swap(false, -2000e6, TickMath.MAX_SQRT_PRICE - 1), _bounded(quote1), "and back, at the fee that way");

        _saleThatAsksBothSources();

        // 4. A day on, the borrower of the vault's loan 1 repays it on gage's core, and anyone settles it in the vault.
        LiveLoan memory first = CORE.getLoan(1);
        LiveLoan memory second = CORE.getLoan(7);
        if (first.state != 2 || second.state != 2) {
            console2.log("the vault's loans 1 and 7 are no longer running at this block: the loan steps are skipped");
        } else {
            vm.warp(block.timestamp + 1 days);
            uint256 value = _vaultValue();
            address borrower = CORE.ownerOf(1);
            deal(USDG, borrower, first.cap);
            vm.startPrank(borrower);
            IERC20(USDG).approve(address(CORE), first.cap);
            CORE.reclaim(1, borrower);
            vm.stopPrank();
            uint256[] memory ids = new uint256[](1);
            ids[0] = 1;
            VAULT.settle(ids);
            assertEq(CORE.getLoan(1).state, 3, "loan 1 is repaid");
            // An early repayment books what the share price had counted; the rest becomes an earnings claim.
            assertGe(_vaultValue() + 2, value, "the pool's share of the vault did not fall");
            console2.log("loan 1 repaid, USDG:", uint256(first.cap) / 1e6);
            console2.log("the pool's value in the vault before and after, raw USDG:", value, _vaultValue());
            _keeperPass();
            _swap(true, -1000e18, TickMath.MIN_SQRT_PRICE + 1);
            _swap(false, -int256(1e12), PAR);

            // 5. Loan 7 runs to its end unpaid: it defaults, the vault writes it off, and the pool bears its share.
            vm.warp(uint256(second.fundedAt) + second.term);
            // From a loan's end to its settle the vault moves no shares; a swap still fills on the float.
            _swap(true, -1000e18, TickMath.MIN_SQRT_PRICE + 1);
            _swap(false, -int256(1e12), PAR);
            value = _vaultValue();
            CORE.finalizeDefault(7);
            ids[0] = 7;
            VAULT.settle(ids);
            assertEq(CORE.getLoan(7).state, 4, "loan 7 defaulted");
            console2.log("loan 7 defaulted, principal USDG:", uint256(second.principal) / 1e6);
            console2.log("the pool's value in the vault before and after, raw USDG:", value, _vaultValue());
            assertLe(_vaultValue(), value, "the write-off is borne by the vault's holders, the pool among them");
            console2.log("the pool's share of the write-off, raw USDG:", value - _vaultValue());
            // The vault takes the borrower's collateral and shares it out; the pool's source claims its part, which
            // goes on to the LPs' beneficiary.
            VAULT.recover(7);
            uint256 pocket = VAULT.pocketCount();
            (uint256 ofLoan, address token,,,,) = VAULT.pockets(pocket);
            assertEq(ofLoan, 7, "the newest pocket is loan 7's collateral");
            assertEq(token, second.token);
            uint256[] memory pocketIds = new uint256[](1);
            pocketIds[0] = pocket;
            usdgSource.claimPockets(pocketIds);
            uint256 claimed = IERC20(token).balanceOf(address(usdgSource));
            usdgSource.forward(IERC20(token));
            assertEq(IERC20(token).balanceOf(partner), claimed, "the recovered collateral reaches the LPs' beneficiary");
            console2.log("loan 7's collateral, claimed for the LPs' beneficiary:", IERC20Metadata(token).symbol());
            _keeperPass();
        }

        // 6. Swaps go on, and the LP leaves with everything: the float and the vault pay it.
        _swap(true, -5000e18, TickMath.MIN_SQRT_PRICE + 1);
        _swap(false, -int256(1e12), PAR);
        uint256 shares = hook.balanceOf(partner);
        vm.prank(partner);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        uint256 back = IERC20(FRXUSD).balanceOf(partner) / 1e12 + IERC20(USDG).balanceOf(partner) - lpBefore;
        console2.log("the LP paid in, USDG:", paidIn / 1e6);
        console2.log("the LP took out, USDG:", back / 1e6);
        if (back >= paidIn) console2.log("gain in dollars, raw USDG:", back - paidIn);
        else console2.log("loss in dollars, raw USDG (before the collateral it received):", paidIn - back);
        assertEq(hook.totalSupply(), 0, "the pool is empty");
        assertGt(back, paidIn - 300e6, "the LP is whole but for its share of the defaulted loan");
        assertLt(back, paidIn + 300e6);
    }
}
