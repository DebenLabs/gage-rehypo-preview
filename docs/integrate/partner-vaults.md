# Partner vaults: lend through one, or run one

A partner vault is a pooled lender: an ERC-4626 vault (`IntentVault`) that takes one asset, USDG or a stock token such as NVDA, and funds fixed-cost loans on its generation's core within the rules its manager wrote at creation, its mandate. On the Intent cores only partner vaults fund loans: a wallet or a contract lends by depositing into a vault, never by funding a listing. **No liquidation:** nothing can touch a borrower's collateral before the end of the loan; at the end the borrower repays, or the vault keeps the collateral. Use this page to list vaults, deposit and redeem, settle a vault's loans and claim what it owes you; and to create a vault, which any address can, and manage its settings. How a vault's money reaches a loan is in [fills.md](fills.md). The product view is [Partner vaults](https://docs.gage.cash/earn/partner-vaults).

You may end up holding the collateral instead of USDG (in a stock-token vault, instead of the asset you lent).

## Contracts

The USDG generation's, by manifest key. Every lend asset has the same set under `intentV1Assets.<SYMBOL>` ([Lend assets](#lend-assets) below).

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| IntentFactory | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` | IntentFactory.sol | IntentFactory.json | Its owner (`owner()`, `Ownable2Step`), a Safe gage controls: it admits creators, classifies collateral tokens, names the quote signer, the fillers, the protocol fee recipient and the secondary fee, and can close fills for every vault. It has no function that moves a vault's assets and cannot change a vault's mandate, but the signer and fillers it names decide which listings vaults fund, within their limits. |
| IntentVault | One per vault: the factory's `vaults(i)` | IntentVault.sol | IntentVault.json | Its curator (`CURATOR()`), the creator, for good: settings within the bounds in code. No owner, no upgrade; the curator cannot withdraw depositors' assets. Created from creation code the factory holds on chain as data, in two parts (the README's USDG table and `codeStores` in `deployments/4663.json` list them); its hash is the factory's `VAULT_INIT_HASH()`. |
| IntentAssetPolicy | One per vault: the vault's `ASSET_POLICY()` | IntentAssetPolicy.sol | IntentAssetPolicy.json | The vault's curator, for the risk limits and the secondary policy; only the vault changes its collateral list. Created by the vault. |
| IntentLenderMarket | One per vault: the vault's `LENDER_MARKET()` | IntentLenderMarket.sol | IntentLenderMarket.json | The vault's curator lists the vault's loans for sale; the factory's exit desk lists for leaving holders. Created by the vault. |
| IntentVaultViews | `0x3c2b782ffd62034C4F02346fEdcBd1f567eDE4aB` (the factory's `SHARE_VIEWS()`) | IntentVaultViews.sol | IntentVaultViews.json | Nobody: stateless reads, created by the factory. |
| GradeRegistry | The factory's `GRADES()` | GradeRegistry.sol | Build from `src/` | Its owner names the `publisher()`, the key gage publishes collateral grades and modeled costs with. Nothing in it moves value. |
| GageV2Vault (the core) | `0x0086EC1540719d4199432797e2b6068E6aE5a0e5` | GageV2Vault.sol | GageV2Vault.json | Nobody: no owner. It holds every loan and its collateral; only the factory's vaults may fund it. |
| Reserve | `0xBeEff033F34C046626B8D0A041844C5d1A5409dd` | ERC-4626 (a Morpho Vault V2 over USDG) | | Its own curators, outside gage. Idle USDG of every USDG vault earns here; its value can rise or fall. |
| MorphoV2ReserveLens | `0x6a702eAEA4f3b45aB352c4F3d5bf721bd0110ceD` (the factory's `RESERVE_LENS()`) | MorphoV2ReserveLens.sol | MorphoV2ReserveLens.json | Nobody: stateless. Measures what the reserve can pay out now, for `freeLiquidity()`. |
| IntentExitDesk | `0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2` | IntentExitDesk.sol | IntentExitDesk.json | Shared by every generation's factory (`exitDesk()`): [exit-desk.md](exit-desk.md). |

## How it works

### Lend assets

Each lend asset has its own generation: its own core, factory, fill router and quote verifier. A factory's vaults take and pay out that asset only, and lend it against the collateral admitted on that core. The factories below run the same code and create their vaults from the same creation code: `VAULT_INIT_HASH()` is equal on all of them.

| | USDG | A lend asset `<SYMBOL>` (GLD, NVDA, HIMS) |
| --- | --- | --- |
| Lend asset | `USDG`, 6 decimals | `intentV1Assets.<SYMBOL>.lendAsset.token`; its decimals at `lendAsset.decimals` (18 for all three) |
| Factory | `intentV1.factory` | `intentV1Assets.<SYMBOL>.factory` |
| Core | `intentV1.core` | `intentV1Assets.<SYMBOL>.core` |
| Fill router, quote verifier | `intentV1.fillRouter`, `intentV1.quoteVerifier` | `intentV1Assets.<SYMBOL>.fillRouter`, `.quoteVerifier` |
| Reserve | `intentV1.reserve`, an ERC-4626 over USDG | `intentV1Assets.<SYMBOL>.reserve`, an `IntentClosedReserve` that takes nothing: idle assets stay the vault's cash, and `investReserve` reverts |
| Grade registry | the factory's `GRADES()` | `intentV1Assets.<SYMBOL>.gradeRegistry` |
| Protocol fee recipient (the factory's `protocolRecipient()`) | `DealFeeRouter` | `intentV1Assets.<SYMBOL>.feeProcessor` ([fills.md](fills.md#where-the-fees-go)) |
| Vault reads | `0x3c2b782ffd62034C4F02346fEdcBd1f567eDE4aB` | the factory's `SHARE_VIEWS()` |

A generation the GenerationDeployer built (frxUSD) is found through it, not under these keys: [generations.md](generations.md). Previous generations, which take no new loans and pay out their vaults until their last loan closes, are under `intentV1Previous` and `intentV1AssetsPrevious`.

Stock-token amounts are raw units on chain, the vault's included; scale by the token's `uiMultiplier()` for display only.

### Shares and their price

Shares are an 18-decimal ERC-20 (`symbol()` is `gSHARE`, `name()` the vault's name at its factory), transferable, priced once for everyone:

```text
totalAssets() = cash() + the reserve shares at the reserve's own conversion + performingPrincipal() + accruedInterest()
convertToShares(assets) = assets × (totalSupply() + 10^12) / (totalAssets() + ASSET_SCALE)       rounded down
convertToAssets(shares) = shares × (totalAssets() + ASSET_SCALE) / (totalSupply() + 10^12)       rounded down
```

`ASSET_SCALE` is `10^(decimals − 6)`: 1 for USDG, 10^12 for an 18-decimal asset. One whole unit of any asset starts worth 10^18 shares.

Each loan counts at the principal the vault paid plus its return earned so far. The return the vault books for a purchase is the quarters' fixed cost less the performance fee (`feeBps` of the fixed cost after the fill's execution fee). It accrues evenly from the second the vault sees the loan active to the end of its term, and stops at the second the core records a repayment. The execution fee leaves priced assets when the vault buys. So a deposit or redemption pays or receives the return accrued to that second: arriving just before a repayment captures nothing.

Not in the price: what a loan ended early would have earned beyond what the price had counted, recovered collateral, and sGAGE. Each is a separate claim (below).

### When a loan ends: settle

`settle(uint256[] ids)` books each loan's outcome. Anyone may call it, gage's keeper does on each pass, and it needs no service.

* **Repaid.** The repayment comes back as cash. If it came before the end of the term, the part of the return the price had not yet counted becomes an earnings pocket, in the lend asset, shared by the shares exposed to the loan while the vault held it, by their share of the vault over that time. Shares that arrive after the repayment take no part.
* **Not repaid by the end of the term.** `settle` finalizes the default on the core and writes the loan off: its value leaves the price, borne by the shares outstanding at that moment. `recover(id)` (anyone) then moves the collateral into a pocket for those shares, in kind. Each holder's part is its balance at the write-off, counted only for the seconds it carried the loan.
* **A listing that missed its funding deadline**, or a commitment the curator released, is refunded at principal.
* **An active loan still in its term** only has its exact end recorded.

The cores have no grace period: repayment closes the second the term ends. From the earliest end of term among the vault's open loans, `earliestMaturity()`, until `settle` books that loan, deposits, mints, redemptions, withdrawals, share transfers, fills and lender sales revert `SettlementDue()`, and `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` read zero. The price does not pause: `totalAssets()` still counts that loan at its full value, principal and whole return after fees, so nobody enters or leaves at that price. Settling it opens them again.

### Claims outside the share price

They belong to the holder that earned them and stay with it after it redeems or transfers its shares.

* **Pockets** (`pockets(pocketId)`, ids 1 to `pocketCount()`): an earnings pocket in the lend asset, a written-off loan's recovered collateral, or backing anyone added to a written-off loan with `recapitalize(id, assets)` (at least one whole unit). `pocketClaimable(pocketId, who)` is what `who` may still take; `claimPocket(pocketId)` or `claimPockets(pocketIds)` pays it.
* **sGAGE** the vault's loans earn, passed to holders by share with no fee: `rewardClaimable(who)`, `claimRewards()`. `harvestRewards(ids)` (anyone) collects released sGAGE into the vault. rewards.md.

### The mandate and the manager's settings

The curator chooses the mandate at creation. Its universe, its performance fee and its longest term are fixed for good. The risk limits only start at their creation values: each later change goes through the vault's asset policy, a tightening at once and a loosening after `LIMIT_LOOSEN_DELAY()`, 3 hours (10,800 s), after which anyone may apply it. Adding a collateral token waits 3 hours too; removing one applies at once. No change touches a loan already funded: a limit now exceeded only refuses new purchases.

A pause stops deposits, mints, reserve investment, fills and lender sales. It never stops redemptions, withdrawals, claims, `settle` or `recover`. The curator can also close the vault to fills (`setFillersOpen(false)`).

### Collateral categories and grades

Every collateral token has one `IntentCategory`, set once by the factory's owner for a token the core's registry admits (`assignCategory`); it can never change. A vault lends against one universe: real-world assets (`STOCK` = 0, `COMMODITY` = 3) or the Robinhood ecosystem (`MEME` = 1, `RH_ECOSYSTEM` = 2). `eligibleCategory(token, mask)` on the factory returns the token's category, or 255 when the token is unclassified, outside `mask` or no longer admitted. A purchase rechecks it.

The grade registry holds two figures gage publishes (`publisher()`). Either reads 0 once it is more than `MAX_AGE`, 7 days, old:

* `gradeOf(token)`: a collateral grade, rank 1 (D) to 10 (AAA), 0 unrated. A vault with `minGrade()` above 0 refuses a token graded below it.
* `modeledCostOf(token, term)`: the model's cost of a reference loan against `token` for `term`, in basis points of principal. A vault with a Loan grade floor (`minRateGrade()`, 1 D, 2 C, 3 B, 4 A) funds a loan only if its fixed cost, after the execution fee and before the performance fee, keeps at least 50%, 75%, 90% or 100% of that cost (`IntentFeeMath.floorPct`, rounded up to the raw unit). With no published cost such a vault funds nothing. [Loan grades](https://docs.gage.cash/start/ratings).

### Fees

* **Performance fee.** `feeBps()`, 500 to 1,500 basis points, fixed at creation, on each loan's fixed cost less its execution fee: `fee = (payout − principal − executionFee) × feeBps / 10,000`, rounded down (`IntentFeeMath.performanceFee`). It is charged when a repayment or a sale is booked, never on a refund, a write-off, collateral, rewards or a deposit. The protocol's part is `PROTOCOL_SHARE_BPS`, 1,000 (10%) of the fee, fixed for every vault; the curator keeps the rest. Both are held apart from depositors' assets (`curatorFees()`, `protocolFees()`) until `claimFees()`, which anyone may call, pays the curator's part to `feeRecipient()` and the protocol's to the factory's `protocolRecipient()` of that moment.
* **Execution fee.** Each fill pays one, at most `executionCapBps()` of the purchase's fixed cost and never so much that the rest falls under the Loan grade floor. It goes to the protocol: [fills.md](fills.md).
* **Secondary fee.** A vault that buys a running loan from another vault pays the factory's `secondaryFeeBps()`, 1,000 (10%) today and at most 2,000, of what the bought quarters repay beyond their price.

A worked example: a vault lends 1,000 USDG for 7 days at a fixed cost of 50 USDG, 5% for the 7 days. The fill's execution fee is 5 USDG; the vault's fee is 1,000 basis points. If the borrower repays, the fee is (50 − 5) × 10% = 4.50 USDG: 0.45 USDG the protocol's and 4.05 USDG the curator's. The vault books 45.50 USDG of return, accrued over the 7 days, after the 5 USDG execution fee left its assets: depositors earn 40.50 USDG, 4.05% for the 7 days. A borrower who walks away pays no fee, and the depositors hold the collateral.

## Call sequences

Amounts are raw units of the vault's asset. Read the asset with `asset()` and its `decimals()`.

### Depositors

**Find vaults.**

1. On each factory, `count()` and `vaults(uint256 index)` for `index` from 0, or `isVault(address)` to check one. `nameOf(address vault)` is its name; `VaultCreated` and `VaultNamed` give the same from events. The public API lists every current vault with its figures: `GET https://mcp.gage.cash/v1/earn/vaults`.
2. On the vault: `asset()`, `totalAssets()`, `freeLiquidity()`, `totalSupply()`, `convertToAssets(10**18)` (one whole share), `paused()`, `earliestMaturity()`, `feeBps()`, `MAX_TERM()`.

**Deposit.**

1. Check `paused()` is false and `block.timestamp < earliestMaturity()`; otherwise settle first (below).
2. `maxDeposit(address receiver)`: the most it takes now. It is zero while paused, during a settlement due and in the second the vault buys a loan. There is no deposit cap besides the share supply's (10^27 shares).
3. `previewDeposit(uint256 assets)` gives the shares. Set `minShares` under it by your slippage (gage-sdk uses 0.5%).
4. On the asset: `approve(vault, assets)`.
5. `deposit(uint256 assets, uint256 minShares) returns (uint256 shares)`. The caller pays and receives the shares. `assets` is at least one whole unit of the asset: 1 USDG is 1,000,000; 1 NVDA is 10^18.

The ERC-4626 forms `deposit(uint256 assets, address receiver)` and `mint(uint256 shares, address receiver)` work too, with no slippage bound. Every deposit, redemption and transfer first collects each open loan record's sGAGE for the vault, up to 64 records, so its gas grows with them: let the wallet estimate it at the time, with margin. You may end up holding the collateral instead of USDG.

**Redeem.**

1. `maxRedeem(address owner)`: the most shares `owner` can redeem now. It is bounded by free liquidity: cash, plus what the reserve can pay this block (`freeLiquidity()`, the whole vault's). Lent principal comes back only as loans end; there is no queue.
2. `previewRedeem(uint256 shares)` gives the assets. Set `minAssets` under it.
3. `redeem(uint256 shares, uint256 minAssets) returns (uint256 assets)`. The caller's own shares; no approval.

`redeem(uint256 shares, address receiver, address owner)` and `withdraw(uint256 assets, address receiver, address owner)` are the ERC-4626 forms; a spender needs the owner's `approve(spender, shares)` on the vault. The last holder cannot redeem every share while a loan is out (`OutstandingLoans()`), and a redemption that would take every asset while shares stay reverts `Impaired()`: redeem what `maxRedeem` says. To leave with more than free liquidity pays, the exit desk lists one of the vault's loans for you: [exit-desk.md](exit-desk.md).

**Settle a vault's due loans.**

1. If `block.timestamp >= earliestMaturity()`, a loan is due.
2. `rewardRecords(address vault)` on the factory's `SHARE_VIEWS()` returns the vault's open loan records, at most 64, settled ones still owed rewards included. `loans(id)` on the vault gives each record; its fourth field is `maturity`, its sixth `settled`.
3. `settle(ids)` from any account, at most 32 ids a call (`MAX_BATCH`). An id the vault never held reverts `UnknownDeal()`; one already settled only retires its reward record.
4. For a loan written off (`LoanWrittenOff`), `recover(id)` from any account. A failed attempt (a paused token, an illiquid pool) can be retried.

**Claim.**

1. For `pocketId` from 1 to `pocketCount()`: `pocketClaimable(pocketId, you)`. `pockets(pocketId)` returns `(loanId, token, amount, supply, claimed, snapshotId)`; `token` is what it pays.
2. `claimPocket(uint256 pocketId)`, or `claimPockets(uint256[] pocketIds)`, where every id must pay something. Open in every vault state, after a full exit too.
3. `rewardClaimable(you)`, then `claimRewards()`. It reverts `InvalidAmount()` when nothing is owed.

### Curators and creators

**Who may create.** Any address: a wallet or a multisig. Every current factory has `openCreation()` true, so nothing needs gage's approval; `isCreator(address)` names the creators admitted before creation opened. The address that creates a vault manages it, and gage-sdk creates one from your own signer.

**Create.** From the address that will manage the vault:

```solidity
function create(
    IntentVault.Mandate calldata mandate,
    bool secondaryEnabled,
    uint16 secondaryExtraBps,
    bool secondaryOnly,
    string calldata name
) external returns (address vault);

struct Mandate {
    address curator;
    uint16[4] categoryWeights;
    address[] assets;
    uint32 maxLoanTerm;
    uint16 feeBps;
    uint8 minGrade;
    uint8 minRateGrade;
    uint128 maxLoanPrincipal;
    uint16 maxAssetBps;
    uint16 bufferBps;
    uint16 executionCapBps;
}
```

`create` reverts `CreationClosed()` unless the factory has bound its fill router, the caller is admitted (or creation is open), and `mandate.curator` is the caller. A mandate the vault's constructor refuses surfaces as `VaultCreationFailed()`, with no reason: check each bound below, and simulate first. A name that is empty or longer than 48 bytes of UTF-8 reverts `InvalidName()`. The new vault starts with funding open (`fillersOpen()` true) and its fees paid to the curator (`feeRecipient()`). The same call creates the vault's asset policy and lender market (`VaultHelpers`). A DEX that wants one vault per pool token can create them in one step: [Create your pool vaults](https://docs.gage.cash/developers/pool-vaults).

| Field | Meaning | Bound at creation | Later |
| --- | --- | --- | --- |
| `curator` | The vault's manager, for good | The caller | Never changes |
| `categoryWeights` | The most of the vault's assets lent against each category, in basis points, in `IntentCategory` order: `STOCK`, `MEME`, `RH_ECOSYSTEM`, `COMMODITY`. The categories given a weight are the universe | Each ≤ 10,000; at least one above 0; one universe only | Each weight inside the universe moves as a risk limit; a category outside stays 0 for good |
| `assets` | The collateral tokens the vault lends against; an empty list funds nothing | No duplicates; each admitted on the core's registry and classified in a category of the universe | Add after 3 hours; remove at once |
| `maxLoanTerm` | The longest loan the vault funds, in seconds (`MAX_TERM()`) | A term the core's registry allows (`REGISTRY().isTermAllowed`) | Fixed |
| `feeBps` | The performance fee | 500 to 1,500 | Fixed |
| `minGrade` | Collateral grade floor; 0 for none | ≤ `GRADES().MAX_GRADE()`, 10 | `setMinGrade`, at once, never under its creation value (`MIN_GRADE_FLOOR()`) |
| `minRateGrade` | Loan grade floor: 0 none, 1 D, 2 C, 3 B, 4 A | ≤ 4 | Risk limit: up at once, down after 3 hours |
| `maxLoanPrincipal` | The most the vault puts into one listing, raw units; 0 funds nothing | ≤ 10^9 whole units of the asset | Risk limit: down at once, up after 3 hours |
| `maxAssetBps` | The most principal lent against one collateral token, as a share of the vault's assets; 0 funds nothing | ≤ 10,000 | Risk limit: down at once, up after 3 hours |
| `bufferBps` | The share of assets every purchase must leave in free liquidity ("cash kept free"); 0 keeps none | ≤ 10,000 | Risk limit: up at once, down after 3 hours |
| `executionCapBps` | The most a fill's execution fee may take of the purchase's fixed cost; 0 allows none | ≤ 5,000 | `setExecutionCap`, either way, at once |

`secondaryEnabled` lets the vault buy running loans other vaults sell, asking `secondaryExtraBps` (≤ 10,000, an annual rate on the price, converted to the time left) above the model's requirement. `secondaryOnly`, which needs `secondaryEnabled`, makes a vault that only buys running loans and never funds a listing, for good. Chosen at creation, the policy applies at once.

**Change settings.** The curator only, unless the table says anyone.

| Setting | Call | When it applies |
| --- | --- | --- |
| A risk limit | `IntentAssetPolicy.setLimit(IntentLimit limit, uint128 value)`; `IntentLimit` is `MAX_LOAN_PRINCIPAL` 0, `MAX_ASSET_BPS` 1, `BUFFER_BPS` 2, `MIN_RATE_GRADE` 3, `CATEGORY_STOCK` 4, `CATEGORY_MEME` 5, `CATEGORY_RH_ECOSYSTEM` 6, `CATEGORY_COMMODITY` 7 | Tighter or equal: at once, and drops any queued loosening. Looser: queued (`LimitQueued`, `pendingLimit(limit)` gives the value and `readyAt`), then anyone calls `activateLimit(limit)` from `readyAt`. A new loosening replaces the queued one and restarts its wait. `cancelLimit(limit)` drops it. `tightenLimit(limit, value)` refuses a loosening outright. |
| Collateral list | Vault: `setAsset(address token, bool picked)`; `resolveAssetAddition(address token, bool activate)` | Removal (`picked` false): at once. Addition: queued for 3 hours (`ASSET_POLICY().readyAt(token)`), then anyone activates it, with admission rechecked; the curator cancels it with `activate` false. |
| Collateral grade floor | `setMinGrade(uint8 rank)` | At once, from `MIN_GRADE_FLOOR()` to 10 |
| Execution cap | `setExecutionCap(uint16 bps)` | At once, ≤ 5,000. A plan priced on the old cap is refused. |
| Pause | `setPaused(bool enabled)` | At once; redemptions and claims stay open |
| Funding | `setFillersOpen(bool enabled)` | At once; open loans are untouched |
| Fee recipient | `setFeeRecipient(address recipient)` | At once; not zero, not the vault |
| Secondary policy | `IntentAssetPolicy.setSecondaryPolicy(bool enabled, uint16 extraBps)` | Narrowing (off, or asking more): at once. Widening: after `SECONDARY_LOOSEN_DELAY()`, 3 hours, then anyone calls `activateSecondaryPolicy()`; `cancelSecondaryPolicy()` drops it. Each change that applies advances `secondaryRevision()`. |
| Name | Factory: `setName(address vault, string name)` | At once, 1 to 48 bytes; display only |
| Reserve | `divestReserve(uint256 shares, uint256 minAssets)` | Brings reserve shares back to cash. Investing is the fill router's, for an admitted filler, and only while the vault is not paused, open to fills and the factory names a quote signer. |
| A listing not yet active | `withdrawCommitment(uint256 id)` | Releases the vault's quarters of a listing before it activates; `settle` books the refund |
| Sell the vault's part of a running loan | `IntentLenderMarket.list(uint256 id, uint40 deadline, uint16 maxFeeBps)`, `cancel(uint256 id)` | The price falls from keeping 99% of the return still to come above book over 10 minutes (`AUCTION_SPAN`), and stops at 50% for the curator's own listing (`CURATOR_FLOOR_BPS`). Buyers are other vaults: [fills.md](fills.md#secondary-purchases). |
| Fees | `claimFees()` | Anyone, at any time |

## Events to index

On each factory:

```solidity
event VaultCreated(address indexed vault, address indexed curator, address creator, uint256 index);
event VaultHelpers(address indexed vault, address assetPolicy, address lenderMarket);
event VaultNamed(address indexed vault, string name);
event CreatorSet(address indexed creator, bool allowed);
event OpenCreationSet(bool open);
event CategoryAssigned(address indexed token, IntentCategory category);
event ProtocolRecipientSet(address indexed recipient);
event SecondaryFeeSet(uint16 feeBps);
event FillRouterSet(address indexed router);
event QuoteSignerSet(address indexed signer);
event FillerSet(address indexed filler, bool allowed);
event ExitDeskSet(address indexed desk);
```

`VaultCreated` names a new vault, its curator and its index for `vaults(i)`; `VaultHelpers` names its asset policy and lender market, whose events follow. On each vault (`IntentCategory`, `IntentLimit` and `V2State` are `uint8` in topics and data):

```solidity
// Shares (ERC-20 and ERC-4626)
event Transfer(address indexed from, address indexed to, uint256 value);
event Approval(address indexed owner, address indexed spender, uint256 value);
event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
event Deposited(address indexed account, uint256 assets, uint256 shares);
event Withdrawn(address indexed account, uint256 assets, uint256 shares);
// Loans
event LoanFunded(uint256 indexed loanId, uint256 principal, uint8 slots, uint16 feeBps, uint256 executionFee);
event LoanAcquired(uint256 indexed loanId, uint256 price, uint8 slots, uint16 feeBps, uint256 executionFee);
event LoanAccruing(uint256 indexed loanId, uint256 interest, uint40 maturity);
event CommitmentWithdrawn(uint256 indexed loanId, uint256 principal);
event LoanSettled(uint256 indexed loanId, V2State state, uint256 payout);
event ProfitReported(uint256 indexed loanId, uint256 profit, uint256 fee);
event LossReported(uint256 indexed loanId, uint256 principal, uint256 earned);
event LoanWrittenOff(uint256 indexed loanId, uint256 principal, uint64 snapshotId);
event LoanSold(uint256 indexed id, uint256 principal, uint256 proceeds, uint256 stoppedInterest);
event CollateralRecovered(uint256 indexed loanId, address indexed token, uint256 amount);
event ExecutionFeeEarned(uint256 indexed loanId, uint256 amount);
event ExecutionFeeReversed(uint256 indexed loanId, uint256 amount);
event ExecutionFeesCollected(address indexed router, uint256 amount);
event CashHarvested(uint256 amount);
// Claims
event PocketCreated(uint256 indexed pocketId, uint256 indexed loanId, address indexed token, uint256 amount, uint256 supply);
event PocketClaimed(uint256 indexed pocketId, address indexed account, uint256 amount);
event RewardsHarvested(uint256 amount);
event RewardsClaimed(address indexed account, uint256 amount);
event FeesClaimed(address indexed curatorRecipient, uint256 curatorAmount, uint256 protocolAmount);
// Reserve
event ReserveInvested(uint256 assets, uint256 shares);
event ReserveDivested(uint256 shares, uint256 assets);
// Settings
event AssetSet(address indexed token, bool picked);
event AssetAdditionQueued(address indexed token, uint256 readyAt);
event AssetAdditionCancelled(address indexed token);
event CategoryWeightSet(IntentCategory indexed lane, uint16 bps);
event MinGradeSet(uint8 rank);
event MinRateGradeSet(uint8 rank);
event LimitsSet(uint128 maxLoanPrincipal, uint16 maxAssetBps, uint16 bufferBps);
event ExecutionCapSet(uint16 bps);
event FeeRecipientSet(address indexed recipient);
event Paused(bool enabled);
event FillersOpenSet(bool enabled);
```

`AssetSet(token, true)` is emitted for each token at creation and on each activated addition, `AssetSet(token, false)` on removal; `picked(token)` on the asset policy is the current answer. `LoanFunded` is a fill's purchase of a listing and `LoanAcquired` a purchase of a running loan; `LoanAccruing` starts the return's clock. A repayment or refund books with `LoanSettled`, with `ProfitReported` when it returned more than principal; a write-off with `LossReported` and `LoanWrittenOff`. `PocketCreated` opens a claim and `CashHarvested` counts cash that reached the vault outside its books.

On each asset policy:

```solidity
event LimitSet(IntentLimit indexed limit, uint128 value);
event LimitQueued(IntentLimit indexed limit, uint128 value, uint256 readyAt);
event LimitCancelled(IntentLimit indexed limit);
event SecondaryPolicySet(bool enabled, uint16 minExtraAnnualReturnBps, uint64 revision);
event SecondaryPolicyQueued(bool enabled, uint16 minExtraAnnualReturnBps, uint256 readyAt);
event SecondaryPolicyCancelled();
```

On each lender market, `AuctionListed`, `Cancelled` and `Sold` (IntentLenderMarket.sol). On the grade registry:

```solidity
event PublisherSet(address indexed publisher);
event GradeSet(address indexed token, uint8 rank);
event ModeledCostSet(address indexed token, uint32 term, uint32 bps);
```

### Reads IntentVaultViews offers

* `rewardRecords(address vault) returns (uint256[])`: the vault's open loan records, at most 64, settled ones still owed rewards included. These are the ids to pass to `settle` and `harvestRewards`.
* `exitShare(address vault, uint256 id, address who) returns (uint256 exposure, uint256 supply)`: what `who` has carried of holding `id`'s exposure, and the whole of it, as a sale in this second would split it. Zero for a holding with no window, and in its purchase's second.
* `coreLoan(GageV2Vault core, uint256 id)`: the core loan fields a vault reads (account, token, state, term, funding deadline, `fundedAt`, `closedAt`, cap, collateral).

`pocketClaimable`, `indexAt` and `maximum` read the calling vault: call the vault's own `pocketClaimable(pocketId, who)` and ERC-4626 maxima instead. The vault's `readAccountingSlot(uint256 slot)` returns any storage slot of its layout.

## Errors you will meet

On the vault:

| Error | When |
| --- | --- |
| `SettlementDue()` | A deposit, redemption, transfer, fill or lender sale from `earliestMaturity()` until `settle` books that loan |
| `PausedError()` | A deposit, mint, reserve investment, fill or lender sale while paused |
| `InvalidAmount()` | A zero amount; a deposit under one whole unit of the asset; more shares than the owner holds; `settle` with more than 32 ids; a claim that pays nothing; `recapitalize` under one whole unit |
| `Slippage()` | Fewer shares than `minShares`, or fewer assets than `minAssets`; a deposit too small to mint a share |
| `InsufficientLiquidity()` | A redemption above free liquidity; a fill that would leave less than the buffer free |
| `OutstandingLoans()` | The last holder redeeming every share while a loan is out |
| `Impaired()` | Shares outstanding with nothing behind them; or a redemption that would leave them so |
| `RewardsPending()` | A share change while an owed sGAGE claim cannot be collected; nothing changed, retry later |
| `SaleTooSoon()` | A share change in the second the vault bought a loan |
| `LimitExceeded()` | A deposit past 10^27 shares; a fill opening a 65th loan record |
| `InsufficientAllowance()` | `transferFrom`, `redeem` or `withdraw` by a spender beyond the owner's share allowance |
| `InvalidConfiguration()` | A zero receiver or owner, or the vault itself; a setting out of its bound |
| `NotCurator()` | A curator setting from another account; a fill or fee collection not from the factory's fill router |
| `UnknownDeal()` | `settle` of a loan the vault never held; `withdrawCommitment` of a loan it does not hold open |
| `NothingToRecover()` | `recover` of a loan not written off, or already recovered |
| `IneligibleDeal()`, `TransferAmountMismatch()`, `NoHolders()`, `SaleBelowBook()` | Fills and lender sales: [fills.md](fills.md#errors-you-will-meet) |

On the factory: `CreationClosed()`, `VaultCreationFailed()`, `InvalidName()`, `NotManager()` (`setName` by another account) and, for the owner's calls, `InvalidConfiguration()`, `NotAFeeProcessor()`, `FillRouterBound()`, `ExitDeskBound()`. On the asset policy: `NotCurator()`, `NotVault()`, and `InvalidConfiguration()` for a value out of bounds, a category outside the universe, a token already picked or not eligible, or an activation before its time.

## Examples

* PartnerVaults.t.sol: picks a live vault of the USDG factory, deals USDG to a fresh depositor, deposits with a slippage bound, checks the shares and `totalAssets()`, redeems within `freeLiquidity()`, and reads the mandate and its collateral list from `AssetSet` events. `forge test --match-path test/PartnerVaults.t.sol -vv` from `examples/foundry`.
* intent-vaults.ts: every vault of every factory, with its asset, `totalAssets()`, `freeLiquidity()` and the value of a share.
* intent-deposit.ts: the approval and the deposit built and simulated from any address, never sent, with the `writeContract` calls you would send.

```solidity
uint256 quoted = vault.previewDeposit(amount);
uint256 minShares = quoted - quoted * 50 / 10_000; // 0.5% slippage bound
usdg.approve(address(vault), amount);
uint256 shares = vault.deposit(amount, minShares);

uint256 toRedeem = vault.maxRedeem(depositor); // bounded by free liquidity
uint256 out = vault.previewRedeem(toRedeem);
uint256 paid = vault.redeem(toRedeem, out - out * 50 / 10_000);
```

You may end up holding the collateral instead of USDG.

## What not to rely on

* **Free liquidity staying put.** It moves with every fill, deposit and redemption, and with what the reserve can pay this block; `maxRedeem` can be zero while everything is lent. Read it in the block you send, and bound the redemption with `minAssets`.
* **An open vault.** A settlement due, a pause or a purchase second can refuse a deposit at any moment; anyone can settle, but nobody has to.
* **A mandate staying as it is.** The curator can loosen a risk limit or add a token. It applies only 3 hours after it is queued, and the queue is public (`LimitQueued`, `AssetAdditionQueued`): watch it.
* **A loan's collateral being worth the loan.** A borrower who walks away leaves the collateral, which can be worth less than the loan, or nothing; memes can go to zero. The vault never reads a price.
* **The share price only rising.** A write-off lowers it, and so can the reserve.
* **gage's services.** Deposits, redemptions, `settle`, `recover` and every claim need only a wallet. Funding new loans needs gage's keeper and its rates service: a vault whose cash waits for a fill earns nothing meanwhile.
* **Shares carrying claims.** Pockets and sGAGE stay with the holder that earned them; a transfer moves neither.
