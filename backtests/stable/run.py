"""Stable pairs: how much of the real swap volume a rehypo pool fills, by float, and what lending adds.

Each real swap of the live pool is offered whole to a pegged rehypo pool of the given size, at the fee that swap paid.
The pool's price feed is one USDG a coin, so its range is centred on $1. Filled is what the pool's liquidity takes
before the price moves 0.1% from the market or the range ends. Three states of the two vaults:

  nothing borrowed            everything out of the pool can come back at once; no ask
  half borrowed               half of each vault in loans that come back over 14 days on average and are lent again
  half borrowed, with the ask the same, and the kit's anchored hook asks both sources when a swap would move the price
                              too far: up to 10% of each side's backing between two keeper moves

Swap income is the LP's value against holding the two coins, a year, with nothing paid on what is out of the pool:
swap fees less what arbitrage takes. What lending adds is counted beside it, on the whole position, a year, after the
vault's fees:

  nothing borrowed    the USDG out of the pool, all of it in the USDG vault's reserve
  half borrowed       half of each coin out of the pool at what borrowers pay, the other half of the USDG in the
                      reserve, the other half of the other coin idle. Only the coins gage has a lend generation for.
  every coin lendable the same, counting the coins with no lend generation too: a what-if

Usage: python3 run.py  -> results/stable.csv, results/stable.md
"""
import csv
import itertools
import os

import numpy as np

import data
from engine import core

HERE = os.path.dirname(os.path.abspath(__file__))
FLOATS = (0.02, 0.05, 0.10, 0.20, 0.30, 0.50, 1.00)
TAU = 0.001  # the price move that ends a fill
ASK = 0.10  # FAILSAFE_BPS at its bound: the share of a side's backing the ask may draw between two keeper moves
ASK_RULE = 12  # the engine's model of the anchored hook's ask of both sources by price impact
BOTH = np.array([1, 1], np.int64)  # both vaults plain: a share kept free, the rest in loans
NO_RATE = np.zeros(2)
PEGGED, LOCAL_CHECK, ASK_PAYS = 1, 0, 1
RESERVE = 4.02  # % a year: the USDG reserve's 7-day rate on 12 November 2026
BORROW = 6.0  # % a year, assumed: USDG loans against stocks were quoted between 4.0% and 8.1% that day
KEPT = (1 - 0.12) * (1 - 0.065)  # the share of a borrower's fixed cost that reaches depositors (see stock/lending.py)
# state: (share of each vault kept free, the ask on)
STATES = {"nothing_borrowed": (1.0, False), "half_borrowed": (0.5, False), "half_borrowed_ask": (0.5, True)}


def money(v):
    return f"${v / 1000:.3g}k" if v < 1e6 else f"${v / 1e6:.3g}M"


def lending(P, phi):
    """(nothing borrowed, half borrowed, every coin lendable): % a year on the whole position."""
    total = sum(P["held"])
    idle = now = every = 0.0
    for coin, held in zip(P["coins"], P["held"]):
        out = held * (1 - phi) / total
        reserve = RESERVE if coin == "USDG" else 0.0
        half = out / 2 * BORROW * KEPT + out / 2 * reserve
        idle += out * reserve
        every += half
        now += half if data.LENDABLE[coin] else 0.0
    return idle, now, every


def run():
    rows = []
    for key, P in data.POOLS.items():
        D = data.prep(key)
        days = (D["T"][-1] - D["T"][0]) / 86400
        par = np.ones(len(D["T"]))  # the price feed: one USDG a coin
        held = round(sum(P["held"]), -3)  # the live pool's own size
        for K, R, phi, (state, (free, ask)) in itertools.product(sorted({held, 250e3, 1e6}), P["ranges"], FLOATS, STATES.items()):
            if phi == 1.0 and state != "nothing_borrowed":
                continue
            o = core(D["t"], D["d"], D["A"], D["f"], D["p0"], D["T"], D["q"], par, par, K, phi, ASK if ask else 0.0, R, TAU, BOTH,
                     np.array([free, free]), NO_RATE, data.TERM, PEGGED, LOCAL_CHECK, ASK_PAYS, ASK_RULE if ask else 0, 0.0)
            idle, now, every = lending(P, phi)
            rows.append(dict(pair=P["name"], pool_size=K, held=int(K == held), range=f"+-{R / 200:g}%", float=phi, float_a_side=K * phi / 2, state=state,
                             days=round(days, 2), swaps=int(o[27]), volume=round(o[0], 2), filled=o[1] / o[0], swaps_full=o[17] / o[27],
                             swap_income_yr=o[5] * 365.0 / days * 100.0 / K, lending_nothing_borrowed=idle, lending_half_borrowed=now,
                             lending_every_coin=every))
    os.makedirs(f"{HERE}/results", exist_ok=True)
    with open(f"{HERE}/results/stable.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    L = []
    for pair in dict.fromkeys(r["pair"] for r in rows):
        x = [r for r in rows if r["pair"] == pair]
        P = next(p for p in data.POOLS.values() if p["name"] == pair)
        L += [f"**{pair}** ({x[0]['swaps']:,} swaps and ${x[0]['volume'] / 1e3:,.0f}k of volume over {x[0]['days']:g} days. At the snapshot it held "
              f"{money(round(P['held'][0], -2))} of {P['coins'][0]} and {money(round(P['held'][1], -2))} of {P['coins'][1]}.)\n"]
        for rng in dict.fromkeys(r["range"] for r in x):
            L += [f"Range {rng.replace('+-', '±')}:\n",
                  "| Pool size | Float | Float a side | Volume filled: nothing borrowed | Half borrowed | Half borrowed, with the ask | Swaps filled whole | Swap income a year | Lending adds: nothing borrowed | Half borrowed | Every coin lendable |",
                  "|---|---|---|---|---|---|---|---|---|---|---|"]
            for K, phi in dict.fromkeys((r["pool_size"], r["float"]) for r in x):
                g = {r["state"]: r for r in x if (r["pool_size"], r["float"], r["range"]) == (K, phi, rng)}
                a = g["nothing_borrowed"]
                h, k = g.get("half_borrowed", a), g.get("half_borrowed_ask", a)
                size = money(K) + (" (as held)" if a["held"] else "")
                if phi == 1.0:
                    L.append(f"| {size} | 100% (nothing lent) | {money(K / 2)} | {a['filled'] * 100:.0f}% | | | {a['swaps_full'] * 100:.0f}% | "
                             f"{a['swap_income_yr']:.1f}% | | | |")
                else:
                    L.append(f"| {size} | {phi * 100:g}% | {money(K * phi / 2)} | {a['filled'] * 100:.0f}% | {h['filled'] * 100:.0f}% | {k['filled'] * 100:.0f}% | "
                             f"{k['swaps_full'] * 100:.0f}% | {k['swap_income_yr']:.1f}% | {a['lending_nothing_borrowed']:.1f}% | "
                             f"{a['lending_half_borrowed']:.1f}% | {a['lending_every_coin']:.1f}% |")
            L.append("")
    open(f"{HERE}/results/stable.md", "w").write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    run()
