# Exit desk

A partner vault pays a redemption at once, up to its free liquidity (cash plus what its reserve can pay out now). A holder who wants more than that uses `IntentExitDesk`, "exit now": they commit shares at the desk, and the desk lists one of the vault's running loans for sale on the vault's own `IntentLenderMarket`, at a price that falls for ten minutes. When another partner vault buys it, the sale redeems the holder's shares in the same transaction, and the desk holds what they paid until the holder collects it. Only the part of the holding the vault cannot pay the holder may fall to book value, and the holder pays the buyer's discount out of their own share of that loan. One desk serves every generation. Use it to build an "exit now" for a partner vault's depositors, or to read where an exit stands.

A partner vault lends what is deposited: you may end up holding the collateral instead of USDG (for a vault that lends another asset, instead of the asset you lent). An exit, like a redemption, leaves before later outcomes: losses on loans that default after a holder leaves fall on the holders who stay.

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| IntentExitDesk | `0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2` | `src/intent/IntentExitDesk.sol`, interface `src/interfaces/IIntentExitDesk.sol` | `abi/IntentExitDesk.json` | No owner, no upgrade, no arbitrary call |
| IntentLenderMarket | one per partner vault: `LENDER_MARKET()` on the vault | `src/intent/IntentLenderMarket.sol` | `abi/IntentLenderMarket.json` | No owner; the vault's curator lists and cancels its own listings |
| IntentExitRetaker | not deployed on mainnet at this release: no factory admits one | not in this repository until a release deploys it | | No owner; only its `OPERATOR`, gage's filler wallet, would call it |
| IntentFactory (each generation) | `0xB086944b140758b33694220d4Fe93C9A8D8618a1`, `0x2a09498f11A70c4F2AB0a4e1B3323699bF7cC143`, `0xd1Fc8951289372C7260Ac0F7BC830bAbA49F109c`, `0x76030f3fd8631a2839D79fEfBf5EFf124229734a` | `src/intent/IntentFactory.sol` | `abi/IntentFactory.json` | Its owner names the desk (`setExitDesk`) |

Each lend generation's entry names the same desk as `intentV1.exitDesk` (`intentV1Assets.<SYMBOL>.exitDesk`). The desk acts for a vault only while that vault's factory names it (`IntentFactory.exitDesk()`). A factory's owner can set it to zero, which closes exits for all its vaults at once (live exit listings cannot sell until it reopens), or back to the first desk it named (`boundExitDesk()`), never to another. A market lists only for its own vault (`SELLER()`) under its own factory (`FACTORY()`); the factory emits `VaultHelpers(address indexed vault, address assetPolicy, address lenderMarket)` when it creates a vault.

## How it works

**The holding.** A vault's position in one running loan, its lender quarters (`IntentVault.loans(id)`). Its book value is what the vault paid plus the return earned so far; its return still to come is the rest of what the loan pays the vault if it is repaid.

**The falling price.** A listing on a vault's market names no price. A sale must leave the vault's holders `keepBps(id)` of the return still to come on top of book value: 9,900 basis points (`START_KEEP_BPS`) at listing, falling linearly to zero over `AUCTION_SPAN` (10 minutes), never below the listing's floor. The vault refuses a sale that books less (`SaleBelowBook`), after the trade fee. A curator's own listing never falls below `CURATOR_FLOOR_BPS` (5,000). An exit listing falls to the desk's floor (`floorBps(vault, id)`) and ends `EXIT_GRACE` (1 minute) after the fall, 11 minutes after listing; it must end before the loan does.

**The shortfall.** `shortfall(vault, owner)` is what the holder's committed shares are worth beyond what the vault holds outside its loans (cash, and its reserve at the reserve's value, not what the reserve can pay out this instant), and at most their share of the loan book. The shares counted are the least of the commitment, the holder's balance and their approval of the desk. Zero means the vault can pay the holder: the desk lists nothing (`NoShortfall`), and the holder redeems instead.

**The floor of an exit listing** (`floorBps`, read again at the sale):

- 9,900, no fall at all, when the leaver has no shortfall now, while any record of the vault awaits its settlement (`pendingSettlements`), or once the holding has more return still to come per unit of book value than the vault's running loans together (`withinAverage` false);
- otherwise none for the part of the holding the shortfall covers and 9,900 for the rest: `ceil(9900 * (book - need) / book)`, zero when the need covers the whole holding;
- never below the share of the holding the leaver's committed shares did not carry, by loan-days (`IntentVaultViews.exitShare`), of 9,900: the leaver can take off a buyer's price only their own part.

The sale's discount below where a listing starts is charged to the leaver (`exitDebit(vault, id)`, `ExitDebited`): it comes out of the leaver's own part of the earnings claim the sale opens in the vault. Every other holder keeps their share of the return still to come.

**One listing at a time.** An exit has one live listing. Once it sold, ended or passed to another exit, the holder (or a filler the factory admits) lists the next holding (`list`). A holding already under another exit's live listing is listed only by taking that listing over as it stands (its nonce, start and end), and only when this exit's floor there (`floorOf`) is strictly lower than that of the exit it serves, or that exit has no shortfall; the displaced exit gets `ExitDropped` and may list another holding. `IntentExitRetaker` lets gage's keeper take a listing back for the exit it displaced and buy it in one transaction, so no other takeover lands between the two; it calls only the desk's `list` and the fill router's `fillSecondary`, and works only while its factory admits it as a filler (`isFiller`).

**The sale.** Only partner vaults may hold a loan's quarters, so the buyers are partner vaults, through the fill router's `fillSecondary` with a secondary plan signed by the factory's quote signer. The market's `buySplit` makes the vault book the sale, then calls the desk's `onSale`, which redeems the leaver's shares (the least of what the exit commits, `maxRedeem` and the approval) for the vault's asset, credited to the leaver; if nothing can be redeemed the whole sale reverts. A commitment lapses `EXIT_LIFE` (1 day) after it was made: then nothing is listed or paid for it.

### What needs gage's services, and what does not

| Who | Without gage's services | Needs gage's services |
| --- | --- | --- |
| A holder (lender) | `redeem` up to free liquidity; `exitNow`, `list`, `cancel`, `withdraw` at the desk; `settle` the vault's pending records | A buyer: every exit sale is bought through `fillSecondary`, on a plan signed by gage's rates service, sent by an admitted filler: gage's keeper. Without one, a listing stands for 11 minutes and ends unsold |
| A vault's curator | `list` and `cancel` its own holdings on its market (not while an exit listing of that holding is live) | The buyer, as above |
| Anyone | `settle(ids)` on a vault, up to 32 ids a call; every view | |
| A borrower | Nothing changes: a sale moves the loan's quarters from one partner vault to others; its cap, its date and its reclaim right stay as they are | |

gage's keeper may also list the next holding for an open exit (it is an admitted filler). gage-sdk's `earn_exit_now` (in its source) picks the holding to list as gage's app does: among the holdings the desk would list now, those where the desk would stop the price lowest for this exit come first (in whole percent), then the smallest whose book value covers the need, else the largest.

## Call sequences

Amounts are raw units of the vault's asset (USDG: 6 decimals; a lend generation's asset: its own decimals) and raw shares.

### Leave when the vault can pay

`IntentVault.redeem(uint256 shares, uint256 minAssets)` (or the ERC-4626 `redeem(shares, receiver, owner)` and `withdraw`), paid at once up to `maxRedeem(owner)`. No desk involved.

### Exit now

1. Read `maxRedeem(owner)` on the vault. If it covers the shares, redeem instead.
2. Read `pendingSettlements(vault)` on the desk. While it returns ids the desk lists nothing (`SettlementPending`): call `settle(ids)` on the vault first (anyone may).
3. Approve the desk for the shares on the vault: `approve(desk, shares)`. The desk never takes them before a sale; the approval caps what a sale may redeem.
4. Commit and list:

```solidity
function exitNow(IntentVault vault, uint256 shares, uint256 id) external;
```

`shares` must be at most the holder's balance and their approval of the desk. `id` is the vault's loan to list; zero commits and lists nothing (a holder that pools others' exits raises its commitment this way while its listing stands). A new commitment replaces the last and restarts its one-day life. Listing needs a shortfall, a holding within the vault's average, no pending settlements, the vault's market, and at least 11 minutes left on the loan.

5. Watch the market's `AuctionListed` and `Sold`, or the desk's `ExitPaid`. After 11 minutes unsold, list the next holding:

```solidity
function list(IntentVault vault, address owner, uint256 id) external;
```

Called by `owner`, or by a filler the vault's factory admits.

6. Collect what the sales redeemed:

```solidity
function withdraw(IERC20 asset) external returns (uint256 amount);
```

`owed(asset, owner)` reads it first. What the desk owes is by asset, whatever vault the exit left.

### Cancel

```solidity
function cancel(IntentVault vault) external;
```

The shares stay the holder's, and nothing more is listed or sold for the exit. A live listing stays in the market until it ends, but with no leaver behind it its sale reverts, until another exit with a shortfall takes it over.

### Read an exit

- `exits(vault, owner)`: `shares` committed, the holding `id` listed last and its `nonce`.
- `committedAt(vault, owner)`; the exit lapses at `committedAt + EXIT_LIFE()`.
- `shortfall(vault, owner)`, `floorOf(vault, id, owner)`, `floorBps(vault, id)`, `withinAverage(vault, id)`, `pendingSettlements(vault)`, `listings(vault, id)` (the exit a listing serves and its nonce), `exitDebit(vault, id)`.
- On the market: `asks(id)` (`listedAt`, `deadline`, `maxFeeBps`, `slots`, `nonce`, `exit`), `keepBps(id)` (zero for no listing), `nonces(id)`.

### The curator's own listing (IntentLenderMarket)

```solidity
function list(uint256 id, uint40 deadline, uint16 maxFeeBps) external returns (uint64 nonce);
function cancel(uint256 id) external;
```

The vault's curator (`CURATOR()`) lists a whole holding; listing again restarts the fall and invalidates the last nonce. `deadline` must be in the future and no later than the loan's end, and `maxFeeBps` at least the registry's trade fee. A curator's listing stops at 5,000 basis points and cannot replace a live exit listing (`ExitListed`).

```solidity
function buySplit(
    uint256 id,
    uint64 nonce,
    uint128 price,
    address[4] calldata recipients,
    uint128[4] calldata minRewards
) external returns (uint256 proceeds);
```

`buySplit` pays `price` once and delivers each listed quarter to its recipient. Only the factory's fill router may name recipients other than the caller, and the core lets only partner vaults hold quarters, so in practice every purchase goes through `IntentFillRouter.fillSecondary(IntentQuoteVerifier.SecondaryPlan calldata plan, bytes calldata signature)`.

## Events to index

From the desk:

- `event ExitCommitted(IntentVault indexed vault, address indexed owner, uint256 shares)`: a commitment made or replaced.
- `event ExitListed(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint64 nonce)`: holding `id` listed for the exit, or a live listing taken over (same nonce).
- `event ExitDropped(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint64 nonce)`: that listing no longer serves `owner`'s exit; it may list another holding.
- `event ExitPaid(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint256 shares, uint256 assets)`: a sale redeemed `shares` for `assets`, now owed to `owner`.
- `event ExitDebited(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint256 pocketId, uint256 debit)`: the sale's discount charged to the leaver, out of their part of earnings claim `pocketId`.
- `event ExitCancelled(IntentVault indexed vault, address indexed owner)`.
- `event Withdrawn(address indexed asset, address indexed owner, uint256 amount)`: collected.

From each market:

- `event AuctionListed(uint256 indexed id, uint64 nonce, uint8 slots, uint40 listedAt, uint40 deadline, uint16 maxFeeBps, bool exit)`: a listing whose price falls from `listedAt`; `exit` marks the desk's.
- `event Cancelled(uint256 indexed id, uint64 nonce)`.
- `event Sold(uint256 indexed id, uint64 nonce, address indexed buyer, uint8 slots, uint256 price, uint256 proceeds, address[4] recipients)`.

Also: the vault's `LoanSold(uint256 indexed id, uint256 principal, uint256 proceeds, uint256 stoppedInterest)`, the fill router's `SecondaryFilled` and `SecondaryContribution`, and the factory's `ExitDeskSet(address indexed desk)` and `FillerSet(address indexed filler, bool allowed)`.

## Errors you will meet

| Error | Contract | When |
| --- | --- | --- |
| `NotDeskVault()` | desk | the vault is not its factory's, the factory names another desk or none, or its market is not its own |
| `InvalidAmount()` | desk | `exitNow` with zero shares, more than the balance, or more than approved |
| `NoExit()` | desk | `list` or `cancel` with no commitment |
| `NotOwner()` | desk | `list` by anyone but the owner or an admitted filler |
| `ListingLive()` | desk | the exit's own listing is still live, or the holding is under another exit's listing this exit may not take over |
| `NoShortfall()` | desk | the vault can pay the holder now, or the commitment lapsed |
| `AboveAverageYield()` | desk | the holding has more return still to come per unit of book value than the vault's average |
| `SettlementPending()` | desk | a record of the vault awaits `settle` |
| `UnknownListing()`, `NotMarket()`, `NothingToPay()`, `TransferAmountMismatch()` | desk | inside a sale: no exit behind the listing, a caller that is not the vault's market, nothing to redeem (or a lapsed exit); `withdraw` with nothing owed (`NothingToPay`) |
| `NotCurator()`, `ExitListed()`, `InvalidAsk()` | market | `list` or `cancel` by anyone but the curator or the desk; the curator against a live exit listing; a holding not listable (loan not running, deadline outside the loan, fee bound below the registry's) |
| `StaleAsk()`, `UnbookedRecipient()` | market | no live listing at that nonce, or a direct buyer naming another recipient |
| `SaleBelowBook()`, `SettlementDue()` | vault | a price below the falling floor; a loan of the vault past its end awaits `settle` |
| `NotOperator()` | retaker | anyone but its operator |

## Examples

- `examples/foundry/test/ExitDesk.t.sol` checks that every factory names the manifest's desk, reads each vault's market, then, as a depositor, commits shares, shows that nothing is listed while the vault can pay, cancels and redeems.
- `examples/viem/src/routers-exit-desk.ts` reads the desk, the markets and each depositor's exit, builds `approve`, `exitNow`, `list`, `cancel` and `withdraw`, and simulates them as the chain stands.

```solidity
vm.startPrank(holder);
vault.approve(address(desk), shares);
desk.exitNow(address(vault), shares, 0); // commit; list nothing yet
vm.stopPrank();
assertEq(desk.shortfall(address(vault), holder), 0); // the vault can pay: redeem instead
```

## What not to rely on

- **A sale.** A listing sells only if a partner vault's plan prices it at or above the floor within its 11 minutes, and only gage's keeper sends those purchases. A floor of 9,900 does not fall at all.
- **The floor you read before the sale.** The desk reads the shortfall, the settlements, the average and the leaver's commitment again when the listing sells. A deposit or redemption in the same transaction as a takeover can move the comparison; the displaced exit may take the listing back.
- **The reserve paying out.** The shortfall counts the reserve at its value, not what it can pay this instant: a reserve that cannot pay lists no loan and moves no floor.
- **An approval being spent at once.** The desk redeems at the sale, from the approval and balance that stand then; reducing either reduces what the exit can be paid.
- **A retaker being in place.** The manifest names none; read `isFiller` on the factory before relying on one.
- **gage-sdk's exit actions in every release.** `earn_exit_now`, `earn_exit_list`, `earn_exit_cancel` and `earn_exit_collect` are in gage-sdk's source; check that the version you install lists them.
