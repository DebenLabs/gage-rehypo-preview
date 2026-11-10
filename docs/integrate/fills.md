# Fills: how a listing gets funded

A borrower lists collateral on a generation's core, and partner vaults fund the listing whole, all four quarters, in one transaction, through that generation's fill router. Each fill carries a plan gage's rates service signed for that exact listing: the vaults, their quarters, every amount and fee, and the vault settings they were priced on. Only an admitted filler may submit one: gage's keeper wallet, and gage's loop, private-borrow and rollover routers inside their own transactions. You cannot fill a listing yourself, and a plan you did not get from gage is refused. Use this page to know exactly what a fill checks and does, to verify any fill on chain, to index fills, and to preflight a signed plan you hold, such as the one a roll or a leveraged borrow carries. Depositing into the vaults that fund loans is in [partner-vaults.md](partner-vaults.md).

You may end up holding the collateral instead of USDG: every fill lends a vault's deposits against collateral the borrower may leave instead of repaying.

## Contracts

The USDG generation's. Each lend asset has its own fill router and quote verifier, the same code, at `intentV1Assets.<SYMBOL>.fillRouter` and `intentV1Assets.<SYMBOL>.quoteVerifier` (addresses.md).

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| IntentFillRouter | `0xAE9607acb7e14bD37cB714cFf8f35B30443133c8` | IntentFillRouter.sol | IntentFillRouter.json | Nobody: no owner, no upgrade. It holds only execution fees already earned, until they are claimed. |
| IntentQuoteVerifier | `0x6a42924C195C6a38427320C1b49130998a7E75E1` | IntentQuoteVerifier.sol | IntentQuoteVerifier.json | Nobody: no owner. The factory's owner or its current quote signer may revoke a plan before it is used. It moves nothing. |
| IntentFactory | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` | IntentFactory.sol | IntentFactory.json | Its owner, a Safe gage controls, holds the fill settings: `fillRouter()` (zero closes fills; only the first router named, `boundFillRouter()`, can reopen them), `quoteSigner()`, `isFiller(address)`, `protocolRecipient()`, `secondaryFeeBps()`. |
| IntentVault | One per vault ([partner-vaults.md](partner-vaults.md)) | IntentVault.sol | IntentVault.json | Its curator decides whether it takes fills (`setFillersOpen`) and the bounds a fill must meet. |
| GageV2Vault (the core) | `0x0086EC1540719d4199432797e2b6068E6aE5a0e5` | GageV2Vault.sol | GageV2Vault.json | Nobody. Only the factory's vaults may fund it (its rewards ledger's funder gate is the factory). |
| DealFeeRouter | `0xEaE95cD11e1105BF1E82033c918ff17f931B0245` | [Contracts](https://docs.gage.cash/developers/contracts) | | Its owner. The USDG generation's protocol fee recipient: it turns USDG into GAGE for the GAGE floor. |
| IntentAssetFeeProcessor (GLD) | `0xcAB24b35F7A3B4FcC958ac56422F0D86A77C84f2` | IntentAssetFeeProcessor.sol | | Its owner (`owner()`, `Ownable2Step`) sets its pool, its forward target and the one account that may convert (`keeper()`). |
| IntentAssetFeeProcessor (NVDA) | `0x5eF8697a5fD43d4c593c6E087d0F2a2B8ff2E584` | as above | | As above |
| IntentAssetFeeProcessor (HIMS) | `0x53f952a05Ac750aca7591DBa2D386762EfBA637A` | as above | | As above |

gage's filler wallet is the manifest's `rolloverExecutor`, `0xCB14554904b86b3472F960740aE377b5b711A659`. The routers admitted as fillers are `intentV1.loopRouter`, `intentV1.privateRouter` and `intentV1.rolloverRouter` on the USDG factory; read `isFiller` or the `FillerSet` events for any factory.

## How it works

1. **A borrower lists.** `list(...)` on the core opens a listing in `FUNDING`, with its collateral, principal, repayment cap, term and funding deadline (borrowing.md).
2. **gage prices it.** gage's rates service reads the listing and the vaults whose rules take it, sizes each vault's part in whole quarters, and signs a plan for it. If no set of vaults takes all four quarters, there is no plan: the listing waits, and gage's keeper asks again as vaults' room changes, until the funding deadline. The borrower may cancel it at any time before (`cancelFunding(id)` on the core); after the deadline anyone may, and the borrower takes the collateral back.
3. **An admitted filler fills.** It calls `fill(plan, signature, maxReserveShares)` on the fill router. The router has the verifier check and consume the plan, has each vault buy its quarters, requires the listing to have activated in that same transaction, and credits the execution fees to the protocol. Anything that fails reverts everything, the plan's use included: no vault is ever left holding part of a listing that did not start.
4. **The fees move on.** Anyone may call `claim(recipient)` to pay the protocol recipient what the router owes it.

### The plan

A plan is EIP-712 typed data, signed by the factory's `quoteSigner()`. Domain: name `gage Intent quotes`, version `1`, the chain ID (4663), and the generation's quote verifier as `verifyingContract` (`eip712Domain()`). Types, exactly as the verifier hashes them:

```text
Plan(address engine,uint256 listingId,address filler,address token,uint8 kind,uint256 collateral,uint128 principal,uint128 cap,uint32 term,uint32 costBps,uint32 feePolicy,uint64 epoch,uint40 issuedAt,uint40 expiry,bytes32 evidence,Allocation[] allocations)
Allocation(address vault,uint8 units,uint128 principal,uint128 interest,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint8 minRateGrade,uint16 capBps,uint16 managerBps)
```

| Plan field | Meaning |
| --- | --- |
| `engine` | The core. Must be the verifier's `CORE()`. |
| `listingId` | The listing on that core. |
| `filler` | The account that submits it: the router's caller. |
| `token`, `kind`, `collateral`, `principal`, `cap`, `term` | The listing's terms, which must match the core's record exactly. `kind` is 0 (ERC-20); amounts are raw units of the lend asset, `term` seconds. |
| `costBps` | The model's cost of this exact loan, in basis points of principal: the base of every vault's minimum. |
| `feePolicy` | The fee calculation's version: `FEE_POLICY_VERSION()`, 1. |
| `epoch` | The verifier's `epoch()` at signing. `revokeAll()` advances it and kills every outstanding plan. |
| `issuedAt`, `expiry` | Chain timestamps. Usable from `issuedAt` to the second before `expiry`; `expiry` at most `MAX_QUOTE_LIFE()`, 300 seconds, after `issuedAt`. |
| `evidence` | A commitment to the pricing evidence the signer used. The contracts never read it, only sign it. |
| `allocations` | One per vault, in ascending vault address order, each vault once. |

| Allocation field | Meaning |
| --- | --- |
| `vault` | A vault of this factory (`isVault`). |
| `units` | How many of the listing's empty quarters it takes, in quarter order: the first vault the first empty ones. |
| `principal`, `interest` | What it lends and the fixed cost those quarters carry: the core's per-quarter split of the listing's principal and cap. A quarter `i` takes `total / 4`, plus one raw unit while `i < total % 4`. |
| `minimum` | What the purchase must keep after its execution fee and before the performance fee: `minimumInterest(principal, costBps, minRateGrade)`, the Loan grade's share of the model's cost (none 0%, D 50%, C 75%, B 90%, A 100%), rounded up. |
| `executionFee` | What this purchase pays for its execution, in raw units of the lend asset. |
| `maxReserveShares` | The most reserve shares the vault may burn to pay principal plus fee; 0 means cash only. The filler may pass a tighter ceiling, never a wider one. |
| `minRateGrade`, `capBps`, `managerBps` | The vault's `minRateGrade()`, `executionCapBps()` and `feeBps()` the amounts were priced on. A change refuses the plan. |

`planHash(Plan)` on the verifier returns the digest; `consumed(digest)` is true once a fill used it, or once it was revoked.

### What the verifier checks

`consume(plan, signature, filler)` runs only for the factory's current fill router, inside the fill. It checks the plan against the chain as it stands, never against what the signer saw, and refuses with `Refused(Refusal reason)` at the first check that fails, in this order:

1. Fills are open: the factory names a quote signer and a fill router (`FILLS_CLOSED`).
2. The signature recovers to the factory's `quoteSigner()` (`BAD_SIGNATURE`).
3. `issuedAt` is not in the future (`NOT_YET_VALID`); now is before `expiry` (`EXPIRED`); `expiry` is at most 300 seconds after `issuedAt` (`LIFE_TOO_LONG`).
4. The digest is not used or revoked (`CONSUMED`), and `epoch` is the verifier's (`EPOCH_REVOKED`).
5. `engine` is the core (`WRONG_ENGINE`); the caller is the plan's `filler` (`WRONG_FILLER`), and the factory admits it (`FILLER_NOT_ADMITTED`).
6. `feePolicy` is 1 (`WRONG_FEE_POLICY`).
7. The borrower is not the filler (`SELF_DEALING`); the listing is `FUNDING` and before its funding deadline (`LISTING_NOT_FUNDING`); its token, kind, collateral, principal, cap and term are the plan's (`LISTING_CHANGED`); `costBps` is above zero (`NO_MODELED_COST`).
8. At least one allocation (`EMPTY_PLAN`). For each, in order:
   * the vault is the factory's (`UNKNOWN_VAULT`) and comes after the previous one by address (`VAULTS_NOT_ORDERED`);
   * `units` is above zero, enough empty quarters are left, and `principal` and `interest` are exactly those quarters' (`ALLOCATION_CHANGED`);
   * the borrower is neither the vault nor its curator (`SELF_DEALING`);
   * the vault takes the purchase now: not paused, open to fills, with shares outstanding, no loan past its end unsettled, the token still picked and still in an admitted category of its universe, and the token's collateral grade at its floor (`BUYER_UNAVAILABLE`);
   * the vault's Loan grade floor, execution cap and performance fee are the plan's (`MANDATE_CHANGED`);
   * `minimum` is exactly `minimumInterest(principal, costBps, minRateGrade)` (`MINIMUM_MISMATCH`);
   * the fixed cost covers the minimum (`BELOW_RETURN_FLOOR`), and the fee is at most the smaller of `interest × capBps / 10,000` and `interest − minimum` (`FEE_ABOVE_CEILING`);
   * with a Loan grade floor, the vault's grade registry has a cost for this token and term (`NO_MODELED_COST`), and the fixed cost after the fee keeps the floor's share of that cost too (`BELOW_RETURN_FLOOR`), whoever signed;
   * `maxReserveShares` is at most the reserve's `previewWithdraw(principal + executionFee)` plus 1% (`MAX_RESERVE_TOLERANCE_BPS`, 100) (`RESERVE_BOUND`).
9. The allocations take every empty quarter (`INCOMPLETE_PLAN`): a plan always completes the listing.

Then it records the digest as used. A signature never widens a vault's limits: each vault checks again when it buys.

### What each vault checks again

The router calls `purchase(uint256 id, uint8 units, uint256 price, uint256 maxReserveShares, uint256 executionFee)` on each vault, with `price` 0 for a listing. The vault, whoever calls, requires:

* not paused (`PausedError`), shares outstanding (`NoHolders`), the caller is the factory's fill router while the vault is open to fills and the factory names a quote signer (`NotCurator`), no loan past its end unsettled (`SettlementDue`), assets behind its shares (`Impaired`);
* fewer than 64 open loan records for a new one (`LimitExceeded`);
* its asset policy's `quote`: the listing is `FUNDING`, before its deadline, for a term at most the vault's longest, ERC-20 collateral, not the vault's or its curator's own (`IneligibleDeal`); the token picked and in its universe, its collateral grade at the floor, the Loan grade floor on the registry's cost, the most per loan, the category weight and the most per token, measured on its assets after the fee (`IneligibleDeal`); a fixed cost no larger than the principal (`IneligibleDeal`); the fee within the vault's execution cap (`LimitExceeded`);
* a new record of at least one whole unit for a 6-decimal asset, a tenth of one for an asset of more decimals (`InvalidAmount`);
* principal plus fee plus `bufferBps` of its assets within free liquidity (`InsufficientLiquidity`), and no more reserve shares burned than the ceiling (`Slippage`).

It pays from cash first, then the reserve, funds its quarters on the core and books the loan. The execution fee leaves its priced assets now and is owed once the loan is active.

### What the fill router does, in one transaction

`fill(IntentQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares) returns (bytes32 digest)`:

1. `maxReserveShares` has one entry per allocation (`LengthMismatch`). Each vault's ceiling is the smaller of that entry and the signed one.
2. `VERIFIER.consume(plan, signature, msg.sender)`: every check above.
3. Each vault, in order, `purchase(listingId, units, 0, ceiling, executionFee)`. The last purchase fills the fourth quarter and the core activates the loan.
4. The loan must be `ACTIVE` with `fundedAt` this block's timestamp (`NotActivated`).
5. Each vault but the last is settled on this loan (`settle([listingId])`), so all of them start the return's clock at the same activation. Then each hands over its earned execution fee (`collectExecutionFees()`), which must be exactly the signed fee (`FeeMismatch`), and the router emits `Contribution`.
6. The total fee is credited to the factory's `protocolRecipient()` of that moment (`owed(recipient)`), and the router emits `Filled`. No filler share exists.

`collectExecutionFees()` hands over every earned fee the vault holds, so fees a vault earned outside this router's fills make the next fill through it revert `FeeMismatch` until someone sweeps them.

The router also has `claim(address recipient)`, which pays a recipient everything it is owed (anyone may call), `sweepStale(address vault)`, which credits fees a vault holds outside a fill to the current protocol recipient (anyone), and `investReserve(address vault, uint256 assets, uint256 minShares)`, which moves a vault's idle cash into its reserve (admitted fillers only).

### Where the fees go

* **Execution fee.** Per purchase, at most `executionCapBps` of the quarters' fixed cost, and never so much that what is left falls under the vault's minimum: at most `min(interest × capBps / 10,000, interest − minimum)` (`IntentFeeMath.executionFee`, rounded down), and what the plan signed exactly. The vault's books carry it as a cost of the purchase: its performance fee is charged on the fixed cost after it. The router credits it to the protocol recipient in the fill's own transaction.
* **The protocol's part of the performance fee** reaches the same recipient later, through the vault's `claimFees()` ([partner-vaults.md](partner-vaults.md#fees)).
* **The recipient.** A factory accepts as its protocol recipient only a contract that answers `USDG()` with the core's lend asset and answers `availableUSDG()` (`NotAFeeProcessor`). For USDG it is `DealFeeRouter`, which batches USDG into GAGE for the GAGE floor (`process(clipUSDG)`, permissionless, [Contracts](https://docs.gage.cash/developers/contracts)). For a lend asset it is that generation's `IntentAssetFeeProcessor`, which holds the fees in the asset. Its `keeper()` alone may call `convert(uint256 amountIn, uint256 minUsdgOut)`: it sells through one Uniswap v3 pool of the asset and USDG (`pool()`, `poolFee()`), for at least the keeper's minimum and at least the pool's spot price less its fee and `MAX_IMPACT_BPS`, 1%. Then it sends every USDG it holds to `forwardTo()`, itself a USDG fee processor: today that generation's rewards bridge, which carries the fees on to the GAGE floor and pays sGAGE to the generation's vaults and borrowers (rewards.md). Nothing else moves the asset or the USDG (`rescue` refuses both). A stablecoin generation with no Uniswap v3 pool uses `IntentAssetV4FeeProcessor`, the same face over a path of one or two Uniswap v4 pools, held to par less the path's fees and `parMarginBps()` ([generations.md](generations.md)).

### Secondary purchases

A vault can also buy another vault's quarters of a running loan. The selling vault's lender market lists them (its curator, or the exit desk for a leaving holder: [exit-desk.md](exit-desk.md)). Its price falls for 10 minutes from keeping 99% of the return still to come above book. gage's rates service signs a `SecondaryPlan` for the buying vaults, and an admitted filler calls `fillSecondary(IntentQuoteVerifier.SecondaryPlan calldata plan, bytes calldata signature) returns (bytes32 digest)`.

The verifier's `consumeSecondary` makes the same signer, life, use, epoch, engine and filler checks, and also requires:

* `policyVersion` is `SECONDARY_POLICY_VERSION()`, 2;
* the core can deliver one sale to several vaults (`LENDER_SPLIT()`; `UNSUPPORTED_ENGINE`);
* the loan is `ACTIVE` and its end is after `expiry` (`LOAN_NOT_ACTIVE`), its terms are the plan's (`LISTING_CHANGED`), and the borrower is not the filler (`SELF_DEALING`);
* the valuation is at most 5 minutes old at `expiry` (`MAX_EVIDENCE_AGE`; `STALE_EVIDENCE`);
* the seller is one of the factory's vaults, selling through its own market (`MARKET_MISMATCH`), on the listing as it stands (`ASK_CHANGED`), and is not paused or due a settlement (`SELLER_UNAVAILABLE`);
* no buyer is the seller or run by the seller's curator (`SELLER_IS_BUYER`), and no buyer already holds a record of the loan (`EXISTING_RECORD`);
* the buyers' quarter masks cover the listing exactly (`MASKS_INVALID`), each at its fixed per-quarter share of the price (`quarterPrice`; `ALLOCATION_CHANGED`);
* each buyer's secondary policy is the plan's (`POLICY_CHANGED`), and its performance fee and the factory's secondary fee are the plan's (`MANDATE_CHANGED`);
* each buyer's execution fee is exactly the factory's `secondaryFeeBps()` of what its quarters repay beyond their price (`FEE_ABOVE_CEILING`), leaving the model's and the buyer's annual minimum over the time left (`BELOW_RETURN_FLOOR`).

The router has each buyer book its quarters and send its price, pays the seller's market exactly the price (`PaymentMismatch`), checks every quarter reached the vault that paid for it (`RightsMismatch`) and every fee is the signed one (`FeeMismatch`), and credits the fees as for a fill. The selling vault refuses any price that books less than the loan's value plus its listing's share of the return still to come (`SaleBelowBook`).

## Call sequences

### Verify a fill on chain

1. From the transaction's logs, read the fill router's `Filled`: the plan's `digest`, `listingId`, `filler`, `activatedAt`, total `principal`, total `executionFee` and the `protocolRecipient` it was credited to.
2. Read the router's `Contribution` logs with the same `digest`: one per vault, with its quarters, principal, fixed cost and fee. They sum to the `Filled` totals, and their quarters to 4.
3. On the router's `VERIFIER()`: `consumed(digest)` is true.
4. On the router's `CORE()`: `getLoan(listingId).fundedAt == activatedAt` and `principal` matches; `lenders(listingId)` names the vaults (until a quarter is sold).
5. On the router's `FACTORY()`: each vault is `isVault`; the filler is `isFiller` (read at the fill's block, or follow `FillerSet`).
6. To check the signature, decode the plan and signature from the call to `fill` (the transaction's input when the filler called the router directly; a router-wrapped fill passes them inside its own call). `planHash(plan)` must equal `digest`, and ECDSA recovery of `digest` with the signature must give the factory's `quoteSigner()` as it stood at that block (`QuoteSignerSet`).
7. In the same transaction, each vault emitted `LoanFunded(listingId, principal, slots, feeBps, executionFee)`, `LoanAccruing` and `ExecutionFeeEarned`, then `ExecutionFeesCollected(router, amount)`. The core emitted `UnitsFunded` per vault and one `Activated`.

### Preflight a signed plan you hold

To know whether a signed plan would pass now, `eth_call` `consume(plan, signature, filler)` on the verifier with `from` set to the factory's `fillRouter()`. It returns the digest when the plan could be consumed in that block, or reverts `Refused(reason)` with the first check that fails. The call changes nothing. It answers for a listing that already exists. A borrower's app also holds signed plans when it rolls a loan or borrows with leverage (gage-sdk's `rollPlan` and `loopPlan`): a gage router submits those as the filler, for a listing it creates in the same transaction, so simulate that router's own call instead. Send at once either way: a plan dies at `expiry`, and with any change to a vault it names.

### Pay out the execution fees

`claim(address recipient)` on the fill router, from any account: it pays `owed(recipient)` to the recipient and emits `Claimed`. `NothingOwed()` when there is none. For USDG, `DealFeeRouter.process(clipUSDG)` then batches it into the floor once its threshold is reached.

## Events to index

On each fill router:

```solidity
event Contribution(bytes32 indexed digest, address indexed vault, uint8 units, uint256 principal, uint256 interest, uint256 fee);
event Filled(bytes32 indexed digest, uint256 indexed listingId, address indexed filler, uint40 activatedAt, uint256 principal, uint256 executionFee, address protocolRecipient);
event SecondaryContribution(bytes32 indexed digest, address indexed vault, uint8 slots, uint256 price, uint256 repayment, uint256 fee);
event SecondaryFilled(bytes32 indexed digest, uint256 indexed loanId, address indexed filler, address seller, address market, uint8 slots, uint256 price, uint256 executionFee, address protocolRecipient);
event StaleFeesSwept(address indexed vault, address indexed protocolRecipient, uint256 amount);
event Claimed(address indexed recipient, uint256 amount);
```

`digest` is the plan's EIP-712 digest, the plan's identity: one `Filled` or `SecondaryFilled` per digest, after its `Contribution` or `SecondaryContribution` logs, all in one transaction. A `Contribution`'s `interest` is the fixed cost its quarters carry, before any fee.

On each quote verifier, which logs only revocations (a use is the router's `Filled`):

```solidity
event Revoked(bytes32 indexed digest);
event EpochAdvanced(uint64 epoch);
```

On the factory, the settings a fill reads: `FillRouterSet(address indexed router)`, `QuoteSignerSet(address indexed signer)`, `FillerSet(address indexed filler, bool allowed)`, `ProtocolRecipientSet(address indexed recipient)`, `SecondaryFeeSet(uint16 feeBps)`. On each vault, the purchase: `LoanFunded`, `LoanAcquired`, `LoanAccruing`, `ExecutionFeeEarned`, `ExecutionFeeReversed`, `ExecutionFeesCollected`, `ReserveInvested` ([partner-vaults.md](partner-vaults.md#events-to-index)). On the core, `UnitsFunded(uint256 indexed id, address indexed lender, uint8 units, uint256 amount, uint8 filled)` and `Activated(uint256 indexed id, uint40 fundedAt, uint128 fee, uint128 borrowerReward, uint128 lenderReward)`. On a lend asset's fee processor:

```solidity
event Converted(address indexed pool, address indexed forwardTo, uint256 assetIn, uint256 usdgOut, uint256 forwarded);
event PoolSet(address indexed pool, uint24 fee);
event ForwardToSet(address indexed target);
event KeeperSet(address indexed keeper);
event Rescued(address indexed token, address indexed to, uint256 amount);
```

## Errors you will meet

On the fill router:

| Error | When |
| --- | --- |
| `LengthMismatch()` | `maxReserveShares` does not have one entry per allocation |
| `NotActivated()` | The listing is not active, activated in this block, after every purchase |
| `FeeMismatch()` | A vault handed over another fee than the plan signed |
| `PaymentMismatch()`, `RightsMismatch()` | A secondary purchase where the price or a quarter did not move exactly |
| `NothingOwed()` | `claim` of a recipient owed nothing; `sweepStale` of a vault holding no fee |
| `NotAVault()`, `NotFiller()` | `sweepStale` or `investReserve` for a vault the factory did not create; `investReserve` from an account not admitted |
| `InvalidConfiguration()` | The factory names no protocol recipient |

On the quote verifier: `Refused(Refusal reason)`, where `reason` is a `uint8` in the ABI; `NotRouter()` for a `consume` not from the factory's fill router; `NotAuthority()` for a revocation from another account; `InvalidQuarter()` from `quarterPrice` for a quarter not listed.

| `reason` | Refusal | | `reason` | Refusal |
| --- | --- | --- | --- | --- |
| 0 | `NONE` | | 19 | `VAULTS_NOT_ORDERED` |
| 1 | `FILLS_CLOSED` | | 20 | `ALLOCATION_CHANGED` |
| 2 | `BAD_SIGNATURE` | | 21 | `INCOMPLETE_PLAN` |
| 3 | `NOT_YET_VALID` | | 22 | `MANDATE_CHANGED` |
| 4 | `EXPIRED` | | 23 | `MINIMUM_MISMATCH` |
| 5 | `LIFE_TOO_LONG` | | 24 | `BELOW_RETURN_FLOOR` |
| 6 | `CONSUMED` | | 25 | `FEE_ABOVE_CEILING` |
| 7 | `EPOCH_REVOKED` | | 26 | `LOAN_NOT_ACTIVE` |
| 8 | `WRONG_ENGINE` | | 27 | `ASK_CHANGED` |
| 9 | `WRONG_FEE_POLICY` | | 28 | `UNSUPPORTED_ENGINE` |
| 10 | `WRONG_FILLER` | | 29 | `SELLER_IS_BUYER` |
| 11 | `FILLER_NOT_ADMITTED` | | 30 | `MARKET_MISMATCH` |
| 12 | `SELF_DEALING` | | 31 | `POLICY_CHANGED` |
| 13 | `LISTING_NOT_FUNDING` | | 32 | `STALE_EVIDENCE` |
| 14 | `LISTING_CHANGED` | | 33 | `RESERVE_BOUND` |
| 15 | `UNSUPPORTED_COLLATERAL` (no longer returned) | | 34 | `MASKS_INVALID` |
| 16 | `NO_MODELED_COST` | | 35 | `SELLER_UNAVAILABLE` |
| 17 | `EMPTY_PLAN` | | 36 | `EXISTING_RECORD` |
| 18 | `UNKNOWN_VAULT` | | 37 | `BUYER_UNAVAILABLE` |

From a vault's `purchase`, which reverts the whole fill: `PausedError()`, `NoHolders()`, `NotCurator()`, `SettlementDue()`, `Impaired()`, `LimitExceeded()`, `InvalidAmount()`, `InsufficientLiquidity()`, `Slippage()`, `TransferAmountMismatch()`, `RewardsPending()`, and from its asset policy `IneligibleDeal()`, `LimitExceeded()`, `BelowReturnFloor()`, `SecondaryClosed()` and `ExistingRecord()` (as above). From a sale: `SaleBelowBook()`, `SaleTooSoon()` (a gain in the second the position was bought) and, on the market, `StaleAsk()`.

## Examples

* Fills.t.sol: asserts every generation's fill configuration (router bound, verifier, core, signer named, EIP-712 domain, protocol recipient a fee processor of the lend asset, the keeper wallet admitted), shows a fill without gage's signature refused `Refused(2)`, and decodes the latest fill from `Filled` and `Contribution`, checking it against the verifier, the factory and the core. `forge test --match-path test/Fills.t.sol -vv` from `examples/foundry`.
* intent-fills.ts: the recent fills of every generation's router, the current ones' and the previous USDG generation's, with each vault's part and `consumed(digest)`.

```solidity
// Anyone may call fill; a plan the factory's quote signer did not sign is refused.
vm.expectRevert(abi.encodeWithSignature("Refused(uint8)", uint8(2))); // BAD_SIGNATURE
router.fill(plan, new bytes(65), new uint256[](0));
```

## What not to rely on

* **A listing being funded.** Nothing obliges a vault or gage to fund it. A listing no set of vaults takes whole waits until its funding deadline; then anyone may cancel it, and the borrower takes the collateral back.
* **Filling it yourself.** Only admitted fillers fill, on plans gage's rates service signs. The vaults' deposits, redemptions, `settle` and claims need neither.
* **A plan staying valid.** It lives at most 5 minutes. It dies with any change to a setting it names (a vault's Loan grade floor, execution cap or fee, a secondary policy revision, the factory's secondary fee), with a revocation or a new epoch, and with any change to the listing.
* **One signer or one recipient for good.** The factory's owner can name another quote signer, admit or remove fillers, and move the protocol recipient for later fills. `Filled.protocolRecipient` is where a fill's fee was credited, and no later setting moves it.
* **The plan's pricing fields.** `costBps` is gage's model's figure and `evidence` an opaque commitment: the contracts hold the vaults to them and to the registry's cost, but never read a price.
* **Partial fills.** There are none: a plan funds every empty quarter, or the transaction reverts.
