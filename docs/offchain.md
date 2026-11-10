# What runs off-chain

The contracts in this tree are everything a rehypo pool has on-chain. The rest runs off-chain: gage's keeper, the
prices it brings, gage's lending services, and a few things on your side. None of that code is in this tree. This page
says what each part does, what it can and cannot do to your pool, and what happens when it stops.

## Who runs what

| Part | Run by | What it does | What it cannot do |
| --- | --- | --- | --- |
| The rehypo keeper | gage | Every 5 minutes it reads each source and, when one is due, moves its float toward the target, re-centres its band and reopens swaps. It ends finished exits, claims what the vault owes the source and forwards rewards and recovered collateral. | Take funds. It calls only what a named keeper may call (`rebalance`, `rebalanceAt`) and calls anyone may make. |
| Signed prices | Nuntius, an independent signer | Signs a price for each token it covers about every 15 seconds. The price source contract checks the signer, the age and the number of sources on-chain. | Move a centre faster than the source allows (`CENTRE_MOVE_BPS` an hour), or past a pegged source's peg. |
| The par feed | Nobody: it is a contract | Values a dollar stable at one USDG. | Anything else. It takes no report. |
| The stablecoin watch | gage | Being added: it watches each stable's price, its issuer and, where it has one, its redemption reserve, and holds gage's quotes in a coin that fails a check. | Touch a pool. It decides only what gage's own services do. |
| Loan pricing and plans | gage | Prices each loan request and signs the plan that says which vaults fund it. | Lend outside a vault's mandate: the vault checks every plan on-chain. |
| The filler | gage | Sends the signed fills, settles loans at their end, recovers collateral after a default and keeps a vault's free cash in its reserve. | Lend without a signed plan, or delay a repayment: settling is open to anyone. |
| The hook check | gage | Before gage serves a pool, it compares the hook's code with the builds it has reviewed. | Stop swaps or exits on a pool it does not serve. |
| The indexer | gage | Follows the factory and every source it creates, for a pool page and for gage's own monitoring. | |
| The sources' owner | You (a Safe) | Creates and binds the sources, names gage's keeper, sets the float target and the beneficiary. | |
| Your fee contract | You | Quotes each swap's fee to the fee hooks. | Charge outside the floor and cap the hook was deployed with. |
| Payouts to LPs | You | Passes on what reaches the beneficiary: sGAGE and collateral recovered from a default. | |

## The rehypo keeper

It passes over every source every 5 minutes. A pass reads; it sends a transaction only when something is due.

**What it sends**

| Call | When |
| --- | --- |
| `rebalance(min, max)` on a stable source with no price | The float is away from its target, swaps are narrower than they should be, or a draw has spent the failsafe's room. The band is gage's for the pool: 0.5% either side of one for one. |
| `rebalanceAt(report)` on a priced or pegged source | The same, or the centre has to move. The report is the token's signed price, or empty where its feed is the par feed. The keeper reads `valueOf` on the price source first and sends nothing the source would refuse. |
| `endExit()` | The first pass a minute after an exit's hour has run (`exitHeldUntil`). |
| `claimPockets`, `claimRewards` | Once a day each. A pocket claim restarts the day over which its proceeds join the float. |
| `forward(token)` | Every pass, when the source holds sGAGE or recovered collateral. It goes to your beneficiary. |

**What a move does on-chain.** It sweeps the float above the target into the vault, refills a float under it from the
vault's free cash, resets what swaps may take (the swap float) to the float, never above the target, records the band
and gives the failsafe its room until the next move. The contract bounds every one of these; the keeper chooses none.

**When it holds back**

| What it sees | What it does |
| --- | --- |
| A pegged coin's price further than the peg from a dollar | Sends nothing: the source would refuse (`OffPeg`). Swaps stay as the last move left them, and gage looks into it. |
| No fresh price, or one the price source refuses | Sends nothing, and gage looks into it. A signed price is good for at most 5 minutes. |
| A Stock Token under a corporate action | Waits. The source also holds for an hour when the token's multiplier changes. |
| The pool's price outside the band | Still sweeps and refills, but reopens swaps to at most 1% of the target, less the further out the price is. gage looks into a pool that stays outside for 10 minutes. |
| The vault between a loan's end and its settlement | Waits: the source refuses moves until the loan is settled, which the filler does. |
| It cannot send (its wallet) | gage looks into it. |

**If the keeper stops.** Swaps go on with the swap float as the last move left it and narrow as it is used. Nothing is
swept, refilled or re-centred. LPs can still leave: an exit takes the float and the vault's free cash without a keeper.
Your Safe can name another keeper at any time (`setKeeper`). A keeper of your own must use gage's band for the pool
exactly: on a stable source a keeper chooses the band, up to about 1% either side, and a band other than gage's can pay
whoever pushed the price.

**The emergency lever.** Your Safe calls `setFloatBps(10000)` on a lent source. The raise applies at once: nothing more
goes to the vault, and each keeper pass pulls the float back from the vault's free cash as loans repay.

## Prices

- **A priced token** (a Stock Token against USDG). The keeper fetches Nuntius's signed price and passes it to the source.
  On-chain, `NuntiusPriceSource` checks that a named signer signed it, that it is no older than the asset's limit (at
  most 5 minutes) and that enough sources fed it. The source takes only a report newer than the last one it centred
  on. Nuntius is a third party; the signers a feed accepts are named on-chain by the feed's owner.
- **A dollar stable nobody signs a price for.** Its feed is `RehypoParPriceSource`: one whole token for one whole USDG.
  There is nothing off-chain to trust in the price itself. What protects the pool is the source's own band, which
  shuts swaps to a sliver once the pool trades past it, and the stops below.
- **The stablecoin watch, being added.** gage's services are to watch each such coin: its price over 5 minutes against
  a dollar, the reserve its redemption module holds where it has one, and any change at its issuer (a new minter, an
  upgrade, a new admin, a pause). A coin that fails a check is held: gage quotes no loan in it until the check clears,
  or, for an issuer change, until gage has looked at it. It is built and not yet released.
- **Not built yet.** Two stops are planned and not in place: the keeper sending no move while gage holds a coin, and
  the keeper sending no move while the pool's own price is more than 0.25% from the centre.

## Lending: from the vault's cash to a loan and back

A source does not lend. It deposits into a gage partner vault, and the vault lends.

1. **A request.** A borrower puts collateral up on gage's lending core and asks for a loan at a fixed cost and term.
2. **A plan.** gage prices the request and signs a plan: which vaults fund it, and how much each. A vault is a
   candidate once it holds cash; its mandate decides what it takes (the collateral it allows, the grade, the longest
   term, the most per loan and per token, and the share of cash it keeps free).
3. **A fill.** gage's filler sends the plan through the fill router. The vault checks the plan's signature and its own
   mandate on-chain, and only then lends. Without a signed plan no one can lend a vault's money, gage included, and a
   plan can only put it into a loan the mandate allows.
4. **The term.** Nothing runs off-chain on a loan. There is no liquidation and no price is watched.
5. **The end.** The borrower repays by the end of the term, or the lender keeps the collateral. `settle` books either
   outcome and is open to anyone; the filler calls it. After a default, `recover` moves the collateral into the vault,
   where each holder claims its part. The keeper claims the source's part daily and forwards it to your beneficiary.
6. **Between a loan's end and its settlement** the vault refuses deposits and withdrawals, so the source refuses LP
   entries, exits and keeper moves until the settlement lands. Swaps go on with the swap float.

The vault's free cash does not sit idle: the filler keeps it in the vault's reserve, a lending vault that pays on
demand. Refills, draws inside a swap and LP exits take it from there.

## Exits beyond the free cash

An LP whose share is more than the float and the vault's free cash can pay asks for an exit (`exitNow`, in the guide).
On-chain, the source commits vault shares at the exit desk, which sells a loan holding to another vault at a falling
price. Off-chain, gage's filler brings the buying vault's purchase, under a plan gage signs as it does a fill's, and
lists the next holding when one ends unsold. The keeper ends the exit an hour after the last ask.

## The hook check

gage serves a pool on a declared range only when its hook is a build gage has reviewed.

- gage's keeper, the tool that prepares a pool's listing and the SDK's exit path each read the hook's runtime code,
  set its immutables aside and compare the rest with the reviewed builds of the kit's anchored hooks.
- They also read the immutables (the two sources, the fee bounds, the fee contract) and check that both sources take
  the same float target.
- A hook of your own design is reviewed first, and its build is then added to the record. Any change to it is a new
  build and a new review.
- A pool that fails is not served: no keeper moves. Its swaps and exits are untouched.

What gage needs from you for it: the hook's source and build settings, the pool key and both sources' addresses.

## Reading a pool

- **Events.** Everything the keeper and the hook do to a source is in its events and its factory's: `SourceCreated`,
  `SourceSettings`, `SourceFailsafe`, `Rebalanced`, `BandSet`, `Centred`, `VaultDrawn`, `PocketsClaimed`,
  `RewardsClaimed`, `Forwarded`, `ExitRequested`.
- **gage's indexer** follows them and serves each source's state and history to a pool page.
- **The SDK** (`gage-sdk` on npm) prepares an LP's exit from a source, the exit desk included.

## Your side

- **The Safe that owns the sources.** One batch per pool: create the two sources, deploy the hook, initialise the pool,
  bind each source, seed, and name gage's keeper. Afterwards it sets the float target (a raise applies at once, a
  cut after 3 hours), the beneficiary, and a vault for a side that starts with none (after 3 days' notice).
- **Your vaults.** A partner vault is created on gage's factory by whoever will curate it, and its curator, longest
  term and fee are fixed at creation. The curator can pause it and tighten its limits at once; loosening waits 3 hours.
- **Your fee contract.** The fee hooks read `currentFee(poolId, zeroForOne)` at every swap. If the read fails in any
  way the swap pays the floor and goes through.
- **What a default leaves.** Recovered collateral and sGAGE reach the source's beneficiary. Passing them on to LPs is
  yours: for instance an airdrop in proportion to each LP's share at the block of the write-off.
- **Your emissions.** An LP's position is the hook's ERC-20 share, so a list of holders is a list of LPs.

## What a fork cannot show

- **A new loan.** It needs a plan signed by gage. The fork test uses the loans a live vault already holds.
- **The keeper.** The tests play it: an address named as keeper sends the moves.
- **Signed prices.** The tests use a stand-in feed, or the par feed.

## Times to know

| What | How long |
| --- | --- |
| Keeper pass | Every 5 minutes |
| A signed price's life | At most 5 minutes |
| Before gage looks into a pool outside its band | 10 to 15 minutes |
| A cut of the float target | 3 hours after it is asked |
| Notice before a side with no vault starts lending | 3 days |
| What a pocket pays joins the float over | 1 day |
| An exit's proceeds are held for the LP | 1 hour |
| Loan terms on mainnet | 1, 7 and 21 days, as the vault's mandate allows |
