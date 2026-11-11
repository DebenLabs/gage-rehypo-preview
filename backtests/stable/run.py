"""Stable pairs: how much of the real swap volume a rehypo pool fills, and what its LPs earn, by float target.

Each real swap of the live pool is offered whole to a pegged rehypo pool of the given size, at the fee that swap paid.
Filled is what the pool's liquidity takes before the price moves 0.1% from the market or the range ends. Income is swap
fees plus what the vaults pay, as the LP's value against holding the tokens, a year.

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
RANGES = (20.0, 100.0)  # ticks: +-0.1% and +-0.5%
TAU = 0.001  # the price move that ends a fill
FREE = 0.10  # a plain vault's cash kept free
PEGGED, LOCAL_CHECK, ASK_PAYS, DRAW_RULE, DRAW_CAP, FREE_RATE = 1, 0, 1, 0, 0.0, 0.0


def money(v):
    return f"${v / 1000:g}k" if v < 1e6 else f"${v / 1e6:g}M"


def run():
    rows = []
    for key, P in data.POOLS.items():
        D = data.prep(key)
        days = (D["T"][-1] - D["T"][0]) / 86400
        sig, usd = data.signed(key, D["T"])
        vm = np.array(P["vmode"], np.int64)
        rate = np.array([data.RATE_USDG if v == 0 else data.BORROW for v in P["vmode"]])
        kf = np.array([0.0 if v == 0 else FREE for v in P["vmode"]])
        for K, phi, R in itertools.product(sorted({P["today"], 250e3, 1e6}), FLOATS, RANGES):
            o = core(D["t"], D["d"], D["A"], D["f"], D["p0"], D["T"], D["q"], sig, usd, K, phi, DRAW_CAP, R, TAU, vm, kf, rate,
                     data.TERM, PEGGED, LOCAL_CHECK, ASK_PAYS, DRAW_RULE, FREE_RATE)
            yr = 365.0 / days * 100.0 / K
            rows.append(dict(pair=P["name"], pool_size=K, float=phi, float_a_side=K * phi / 2, range=f"+-{R / 200:g}%",
                             days=round(days, 2), swaps=int(o[27]), filled=o[1] / o[0], swaps_full=o[17] / o[27],
                             fees_yr=o[3] * yr, lending_yr=o[4] * yr, income_yr=o[5] * yr))
    os.makedirs(f"{HERE}/results", exist_ok=True)
    with open(f"{HERE}/results/stable.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    L = []
    for pair in dict.fromkeys(r["pair"] for r in rows):
        x = [r for r in rows if r["pair"] == pair]
        L += [f"**{pair}** ({x[0]['swaps']:,} swaps over {x[0]['days']:g} days)\n",
              "| Pool size | Float | Float a side | Volume filled, ±0.1% range | Volume filled, ±0.5% range | Swaps filled whole, ±0.5% | Income a year, ±0.5% |",
              "|---|---|---|---|---|---|---|"]
        for K, phi in dict.fromkeys((r["pool_size"], r["float"]) for r in x):
            a = next(r for r in x if (r["pool_size"], r["float"], r["range"]) == (K, phi, "+-0.1%"))
            c = next(r for r in x if (r["pool_size"], r["float"], r["range"]) == (K, phi, "+-0.5%"))
            L.append(f"| {money(K)} | {phi * 100:g}% | {money(K * phi / 2)} | {a['filled'] * 100:.0f}% | {c['filled'] * 100:.0f}% | "
                     f"{c['swaps_full'] * 100:.0f}% | {c['income_yr']:.1f}% |")
        L.append("")
    open(f"{HERE}/results/stable.md", "w").write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    run()
