# Backtests: stable and stock pairs

Real swaps of live pools on Robinhood Chain, replayed through a Python model of the rehypo source and the kit's
anchored hook. They answer one question: how much of a pool's money can be out of the pool, lent, while its swaps still
fill.

**What this is, and is not.**

- **A model, not the contracts.** `engine.py` re-implements the source's float, caps, band and keeper moves and the
  hook's sizing in Python. The contracts it follows are this tree's (`src/rehypo`, `integrations/lender-amm`), which
  are not deployed and not reviewed.
- **Replays, not live results.** No pool runs on these sources yet.
- **Real flow, replayed on a different pool.** Each swap is the one a live pool really took. A pool with less in it
  would not have drawn exactly the same swaps.

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
cd ../stock && python3 run.py        # results/floatfit_<pool>.csv, results/floatfit.md (a few minutes)
python3 lending.py                   # results/lending.csv, results/lending.md
```

The results in this tree are these scripts' own output.

## Stable pairs

frxUSD/USDG over 30 days (1,821 swaps) and eUSD/USDG over 8 days (301 swaps), to 9 November 2026.

- Each real swap is offered whole to a pegged rehypo pool of a given size, at the fee that swap paid.
- **Filled** is what the pool's liquidity takes before the price moves 0.1% from the market, or the range ends.
- Before every real swap and after every keeper pass, arbitrage trades the pool back to within the fee of the market.
- A keeper pass every 5 minutes moves the float toward its target and centres the range on the signed price.
- **Income** is swap fees plus what the vaults pay, as the LP's value against holding the tokens, a year. So every
  loss to arbitrage is in it.
- The USDG out of the pool earns 4.09% a year, what the USDG vault's reserve paid on 10 November 2026. The other coin
  is lent at an **assumed** 7% a year over 14 days on average, with a tenth of it kept free.

frxUSD/USDG on a $250k pool, ±0.5% range:

| Kept in the pool | Each side | Volume filled | Income a year |
| --- | --- | --- | --- |
| 2% | $2.5k | 64% | 5.7% |
| 5% | $6.25k | 79% | 5.7% |
| 10% | $12.5k | 89% | 5.4% |
| 20% | $25k | 95% | 5.0% |
| 30% | $37.5k | 97% | 4.5% |
| 100% (nothing lent) | $125k | 96% | 1.3% |

What fills swaps is a dollar amount, set by the pair's swap sizes, so a larger pool can keep a smaller share: on $1M,
5% kept in the pool fills 95%. The live pool held about $25k, where 10% in the pool fills 50% and all of it 86%.

Every size, both pairs and the ±0.1% range: [stable/results/stable.md](stable/results/stable.md).

## Stock pairs

NVDA, TSLA, SPY and GLD against USDG, eight weeks of each live pool's swaps to 9 November 2026.

- The pool's range is centred at each keeper pass on a stand-in for the signed price (below).
- The window runs week by week. Each week's pool is given the money the live pool had then: the snapshot's money
  scaled by that week's depth at the price.
- For each share of the USDG kept in the pool, the run takes the best of seven range and band shapes.
- The stock kept in the pool is worth 1.5 times the USDG kept, in dollars. Stock pools hold far more stock than USDG,
  so that is a small share of the stock.
- **Filled whole**: the swap fits inside 5% of the price. **Within 5 bps of the live pool**: filled whole, and paid
  no more than 0.05% less than the live pool really paid for that swap.

At the setting each pool's table suggests:

| Pool | USDG in the pool | Stock in the pool | Range, band | Within 5 bps of the live pool | Same pool, nothing lent |
| --- | --- | --- | --- | --- | --- |
| NVDA/USDG | 25% | 4% | ±4%, ±0.35% | 90.5% | 95.0% |
| TSLA/USDG | 20% | 60% | ±3%, ±0.30% | 85.2% | 87.8% |
| SPY/USDG | 50% | 16% | ±8%, ±0.5% | 81.1% | 87.7% |
| GLD/USDG | 60% | 49% | ±8%, ±0.5% | 84.0% | 93.0% |

Every float: [stock/results/floatfit.md](stock/results/floatfit.md).

### What lending adds

`lending.py` is arithmetic on those rows, not a forecast of demand. On the whole position, a year, before the vault's
fee:

- the USDG out of the pool that nobody borrows earns what the USDG vault's reserve pays (4.09%);
- the borrowed share of the USDG and the stock out of the pool earns what borrowers pay, a fixed cost: the mean of
  gage's 7- and 21-day loan quotes against each stock on 11 November 2026 (NVDA 9.8%, TSLA 10%, SPY 5.2%, GLD 4.8%).

| Pool | Out of the pool | Half of it borrowed | All of it borrowed |
| --- | --- | --- | --- |
| NVDA/USDG | 94% | 4.8% | 9.2% |
| TSLA/USDG | 67% | 4.4% | 6.7% |
| SPY/USDG | 78% | 2.2% | 4.1% |
| GLD/USDG | 47% | 1.4% | 2.3% |

Rewards are left out. With nothing borrowed the same settings add 0.3% (NVDA), 2.2% (TSLA), 0.4% (SPY) and 0.6% (GLD)
a year, all of it the reserve. Every float: [stock/results/lending.md](stock/results/lending.md).

## The data

| File | What |
| --- | --- |
| `*/data/<pair>.npz` | One row a swap, from the pool's Swap events: `block`, `li` (log index), `a0` and `a1` (the swap's two amounts, raw units, negative = paid in), `sqrtP` (the square root of the raw price after the swap), `L` (liquidity), `fee` (pips). |
| `*/data/blocktimes.json` | `[block, unix time]` samples. A swap's time is interpolated between them. |
| `stable/data/frxusd_usdg_signed.npz` | frxUSD's price over USDG's at each 5-minute pass, from hourly prices of both coins. Price data by [CoinGecko](https://www.coingecko.com). eUSD/USDG runs on a flat $1. |
| `stock/data/<pair>_ref.npz` | At each pass, the median of exchange 5-minute closes of the tokenized stock, in dollars. A stand-in for the signed price. |
| `stock/data/pools.json` | Each pool's USDG and stock, in dollars, at block 110,615,000, and how its swap log reads. |

## Limits

- **Thin, short stable data.** One month of small pools. eUSD/USDG has 8 days, and its flat $1 price misses the coin's
  own level: its ±0.1% range never fills more than 17%.
- **The 7% on the other stablecoin is assumed**, and so is every borrowed share in `lending.py`.
- **Stock fills are probably flattering.** Most of a stock pool's flow is arbitrage, which a thinner pool would see
  less of, and sizing each week's pool to the live pool's depth favours the older weeks.
- **One window.** NVDA fell 18% over it.
- **The stand-in is not the signed price.** A pool's real centre comes from a signed price, at most 5 minutes old.
  On 11 November 2026 a signer covered NVDA and TSLA on the chain, not SPY or GLD.
- **Not modelled:** gas, a stale or closed-market price, stock splits, the vault's fee, and the rewards a loan pays.
