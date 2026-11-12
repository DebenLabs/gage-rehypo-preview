# Backtests: stable and stock pairs

Real swaps of live pools on Robinhood Chain, replayed through a Python model of the rehypo source and the kit's
anchored hook. They answer two questions: how much of a pool's money can be out of the pool while its swaps still
fill, and what lending adds once half of that money is borrowed.

**What this is, and is not.**

- **A model, not the contracts.** `engine.py` re-implements the source's float, caps, band and keeper moves and the
  hook's sizing in Python. The contracts it follows are this tree's (`src/rehypo`, `integrations/lender-amm`), which
  are not deployed and not reviewed.
- **Replays, not live results.** No pool runs on these sources yet.
- **Real flow, replayed on a different pool.** Each swap is the one a live pool really took. A pool with less in it
  would not have drawn exactly the same swaps.
- **Half borrowed is an assumption**, not a forecast of demand.

## Corrected on 13 November 2026

The first cut (11 November) had errors that flattered the stock tables. This cut replaces every table.

- **Stock pools were sized from depth, not money.** Each week's pool got the snapshot's money scaled by the live
  pool's depth at the price that week. Depth follows how tight the LPs sit, not what they hold: against the pools'
  real holdings, the modelled NVDA pool was 5 to 18 times too large in seven of eight weeks, and SPY 4 to 5 times in
  six. Each week's pool now gets the money and the split the live pool really held (`stock/data/holdings_weekly.json`).
  At the first cut's settings and on its own eight weeks, "within 5 bps of the live pool" falls from 90.5% to 85.3%
  (NVDA), 85.2% to 75.3% (TSLA), 81.1% to 65.5% (SPY) and 84.0% to 69.8% (GLD).
- **Fills and lending used different states.** Fills assumed nothing was borrowed; `lending.py` then priced the same
  rows as borrowed. Fills are now run with half of each vault in loans.
- **`lending.py` counted the stock out of the pool as borrowed at the USDG quote**, for stocks with no lend
  generation too, and left out the vault's fees. It now shows the USDG side and the stock side apart.
- **The stable table ran with the hook's ask of both sources off**, and its income was mostly assumed rates. Fills
  now come with and without the ask, and swap income and lending are shown apart.
- **More pools, newer data.** frxUSD/aUSD and CRCL/USDG are added; every log runs to 12 November.

## What is here

| Path | What |
| --- | --- |
| `stable/` | Stable pairs: `engine.py` (the model), `data.py`, `run.py`, the swaps in `data/`, the tables in `results/`. |
| `stock/` | Stock pairs: the same, plus `lending.py` for what lending adds. |
| `requirements.txt` | numpy and numba. |

## Run it

Python 3 with numpy and numba.

```bash
pip install -r requirements.txt
cd stable && python3 run.py          # results/stable.csv, results/stable.md
cd ../stock && python3 run.py        # results/floatfit_<pool>.csv, results/floatfit.md (several minutes)
python3 lending.py                   # results/lending.csv, results/lending.md
```

The results in this tree are these scripts' own output.

## Stable pairs

The three stable pools of $10k or more on the venue, to 12 November 2026: frxUSD/USDG over 43 days (2,639 swaps),
eUSD/USDG over 11 days (673 swaps) and frxUSD/aUSD over 52 days (587 swaps).

- Each real swap is offered whole to a pegged rehypo pool of a given size, at the fee that swap paid.
- The pool's price feed is one USDG a coin (`RehypoParPriceSource`), so its range is centred on $1.
- **Filled** is what the pool's liquidity takes before the price moves 0.1% from the market, or the range ends.
- Before every real swap and after every keeper pass, arbitrage trades the pool back to within the fee of the market.
- A keeper pass every 5 minutes moves the float toward its target.
- **The ask**: when a swap would move the price too far, the anchored hook asks both sources for more, up to 10% of
  each side's backing between two keeper moves (`FAILSAFE_BPS` at its bound; the set-up script's default is 0).
- **Half borrowed**: half of each vault sits in loans that come back over 14 days on average and are lent again.

Each pool at its own size, a 10% float on each side:

| Pool | Held | Range | Float a side | Volume filled: nothing borrowed | Half borrowed | Half borrowed, with the ask | Same pool, nothing lent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| frxUSD/USDG | $22k | ±0.25% | $1.1k | 58% | 58% | 64% | 94% |
| eUSD/USDG | $159k | ±0.5% | $7.95k | 53% | 53% | 60% | 96% |
| frxUSD/aUSD | $280k | ±0.2% | $14k | 61% | 61% | 72% | 92% |

- **Half borrowed changes nothing here**: the vaults' free half is far more than a keeper pass ever takes.
- **What fills swaps is a dollar amount**, set by the pair's swap sizes. frxUSD/USDG at $250k fills 94% with a 10%
  float ($12.5k a side) and 96% with the ask; at its own $22k a 30% float fills 79% with the ask.
- **frxUSD/aUSD's window has swaps of $20k to $30k**: 56% of its volume is in swaps over $5k, which a $14k float
  cannot take. A 30% float fills 84% with the ask.

### What lending adds

On the whole position, a year, after the vault's fees. Un-lent USDG sits in the USDG vault's reserve (4.02% a year
on 12 November 2026); un-lent frxUSD, eUSD and aUSD earn nothing. Borrowers are **assumed** to pay 6% a year (USDG
loans against stocks were quoted between 4.0% and 8.1% that day), and depositors keep 82% of it (see the stock
pairs). gage had a lend generation for USDG and frxUSD, none for eUSD or aUSD.

| Pool, 10% float | Nothing borrowed | Half borrowed | Half borrowed, every coin lendable (a what-if) |
| --- | --- | --- | --- |
| frxUSD/USDG | 2.0% | 3.2% | 3.2% |
| eUSD/USDG | 2.2% | 2.4% | 3.3% |
| frxUSD/aUSD | 0.0% | 0.8% | 2.2% |

**Swap income is not netted against this.** The model's own swap income (fees less what arbitrage takes) for the
$22k frxUSD/USDG pool is 6.2% a year at a 10% float and 7.6% with nothing lent.

Every size, float and range: [stable/results/stable.md](stable/results/stable.md).

## Stock pairs

The five largest stock/USDG pools on the venue: GLD, SPY, NVDA, CRCL and TSLA, eight weeks of each live pool's swaps
to 12 November 2026 (seven for CRCL).

- The pool's range is centred at each keeper pass on a stand-in for the signed price (below).
- The window runs week by week. Each week's pool is given the money and the split the live pool really held that
  week.
- For each share of the USDG kept in the pool, the run takes the best of seven range and band shapes.
- The stock kept in the pool is worth 1.5 times the USDG kept, in dollars, set each week from that week's split.
- **Filled whole**: the swap fits inside 5% of the price. **Within 5 bps of the live pool**: filled whole from the
  live pool's price before the swap, and paid no more than 0.05% less than the live pool really paid. It says the
  pool is as deep as the live pool for that swap, not that it would have sat at the same price.
- **The pick**: the least USDG float that keeps nine tenths of the volume the same pool fills within 5 bps with
  nothing lent.

At each pool's pick, with the snapshot's holdings:

| Pool | Held, share in USDG | USDG in the pool | Stock in the pool | Range, band | Same pool, nothing lent | Within 5 bps of the live pool: nothing borrowed | Half borrowed | Three quarters borrowed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GLD/USDG | $1.10M, 18% | 75% | 24% | ±8%, ±0.5% | 83.3% | 76.6% | 76.6% | 76.6% |
| SPY/USDG | $1.01M, 19% | 75% | 26% | ±8%, ±0.5% | 85.3% | 79.8% | 79.8% | 79.8% |
| NVDA/USDG | $230k, 12% | 25% | 5% | ±3%, ±0.3% | 89.6% | 83.9% | 83.6% | 81.1% |
| CRCL/USDG | $84k, 3% | 60% | 3% | ±8%, ±0.5% | 65.7% | 62.7% | 62.7% | 61.5% |
| TSLA/USDG | $71k, 83% | 20% | all | ±3%, ±0.3% | 83.6% | 76.0% | 75.8% | 70.7% |

- **The live pool is 100% by definition.** The kit's one shared range is looser than the live pools' LPs sit, so the
  same pool with nothing lent already fills 10 to 34% less of the volume as well.
- **Half borrowed costs at most 0.3 points**, and at most 2.1 if no loan comes back inside a week. A quarter kept
  free costs NVDA 3 points and TSLA 5.
- **SPY and GLD need three quarters of their USDG in the pool** to keep nine tenths of their own fills.
- **The split moves.** NVDA's pool went from 68% USDG to 8.5% over the window, CRCL's from 40% to 4%. The stock
  float above is at the snapshot's split; over the window it averaged 27% of NVDA's stock.

Every float: [stock/results/floatfit.md](stock/results/floatfit.md).

### What lending adds

`lending.py` is arithmetic on those picks at the snapshot's holdings, not a forecast of demand. On the whole
position, a year, after the vault's fees:

- the USDG out of the pool that nobody borrows earns what the USDG vault's reserve pays (4.02%);
- the borrowed half earns what borrowers pay, a fixed cost: the mean of gage's 7- and 21-day USDG loan quotes
  against each stock on 12 November 2026 (GLD 4.0%, SPY 4.0%, NVDA 8.1%, CRCL 5.0%, TSLA 7.6%), of which depositors
  keep 82% (an execution fee of up to 12% of the fixed cost, then a performance fee of 6.5%: a live partner
  vault's settings);
- the stock out of the pool can be lent only where gage has a lend generation for it: GLD and NVDA on 12 November,
  not SPY, CRCL or TSLA. Its un-lent half earns nothing.

| Pool | Out of the pool: USDG / stock | Nothing borrowed | Half borrowed, USDG side | Stock side too |
| --- | --- | --- | --- | --- |
| GLD/USDG | $48.6k / $685k | 0.18% | 0.16% | 1.20% |
| SPY/USDG | $47.0k / $615k | 0.19% | 0.17% | 1.16% (a what-if: no SPY generation) |
| NVDA/USDG | $20.0k / $194k | 0.35% | 0.46% | 3.27% |
| CRCL/USDG | $1.0k / $78.8k | 0.05% | 0.05% | 1.97% (a what-if: no CRCL generation) |
| TSLA/USDG | $47.4k / $0 | 2.68% | 3.42% | 3.42% |

- **Four of the five pools hold 3 to 19% USDG**, so what is out of the pool is almost all stock. Only TSLA's lend
  side is mostly USDG.
- **USDG lent against GLD or SPY pays depositors less than the reserve**: 4.0% less the vault's fees is 3.3%.
- Rewards are left out. Every float: [stock/results/lending.md](stock/results/lending.md).

## The data

| File | What |
| --- | --- |
| `*/data/<pair>.npz` | One row a swap, from the pool's Swap events: `block`, `li` (log index), `a0` and `a1` (the swap's two amounts, raw units, negative = paid in), `sqrtP` (the square root of the raw price after the swap), `L` (liquidity), `fee` (pips). To block 112,796,665. |
| `*/data/blocktimes.json` | `[block, unix time]` samples. A swap's time is interpolated between them. |
| `stock/data/<pair>_ref.npz` | At each pass, the median of exchange 5-minute closes of the tokenized stock, in dollars. A stand-in for the signed price. Closes in USDT are turned into dollars with an hourly USDT price. Price data by [CoinGecko](https://www.coingecko.com). |
| `stock/data/pools.json` | Each pool's USDG and stock, in dollars, at block 112,796,665, and how its swap log reads. |
| `stock/data/holdings_weekly.json` | What each pool held week by week: its dollars and the USDG's share, the mean of one reading a day. Summed from the pool's liquidity events (every position, at the pool's price at the reading). |

A stable pool's holdings at the snapshot are set in the stable folder's loader.

## Limits

- **Swap income is not netted.** A pool that fills less of the volume as well as the live pool earns less from
  swaps, and the live pools' swap fees are large beside what lending adds. These tables do not count that.
- **Half borrowed is assumed.** So is the 6% on stable pairs. Loans come back smoothly in the model; real ones end
  in lumps after 1, 7 or 21 days.
- **Lending the stock side is untested.** It needs borrowers of the stock token.
- **Thin, short stable data.** eUSD/USDG has 11 days, and its fee for paying eUSD went from 1% to 0.01% on 12
  November. The $1 centre does not see a coin off its peg: eUSD traded 0.3 to 0.5% from $1.
- **Stock fills are probably still flattering.** Most of a stock pool's flow is arbitrage, which follows the pool's
  own depth. Each week starts with fresh floats at that week's split, which presumes the float targets are retuned
  as the split moves.
- **The stand-in is not the signed price, and is read with no delay.** A real report is up to 5 minutes old, and
  most of the volume is outside the US market's hours. On 11 November 2026 a signer covered NVDA and TSLA on the
  chain, not GLD, SPY or CRCL.
- **One window.** NVDA fell over it.
- **Not modelled:** defaults, LP exits, gas, a stale or closed-market price, stock splits, and the rewards a loan
  pays.
