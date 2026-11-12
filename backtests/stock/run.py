"""Stock pairs: which float makes sense per pool, and how the fills hold as the money out of the pool is borrowed.

A rehypo pool, its range centred on the signed price, against every real swap of the live pool over the whole window,
in weekly runs. Each week's pool is given the money and the split the live pool really held that week
(data/holdings_weekly.json). For each share of the USDG kept in the pool, the stock kept in the pool is worth 1.5
times those dollars, set each week from that week's split.

For each float: the best of seven range and band shapes with half borrowed, and at that shape the share of volume the
pool would have filled whole, and filled within 5 bps of what the live pool really paid, with

  nothing borrowed          everything out of the pool can come back at once
  half borrowed             half of each vault in loans that come back over 14 days on average and are lent again
  half, none back           the same half in loans that do not come back inside the week
  three quarters borrowed   a quarter of each vault kept free

Usage: python3 run.py [gld spy nvda crcl tsla]  -> results/floatfit_<pool>.csv, results/floatfit.md
"""
import csv
import os
import sys

import numpy as np

import data
from engine import core

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = ["gld", "spy", "nvda", "crcl", "tsla"]
LIM = 0.05
FLOATS = (0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60, 0.75, 1.00)
# range either side, band either side
SHAPES = [(0.01, 0.0015), (0.02, 0.0025), (0.03, 0.0030), (0.04, 0.0035), (0.06, 0.0040), (0.08, 0.0050), (0.10, 0.0050)]
BOTH = np.array([1, 1], np.int64)  # both vaults plain: a share kept free, the rest in loans
NEVER = 1e15  # a loan term no week reaches
# state: share of each vault kept free, the loans' average term
STATES = {"nothing_borrowed": (1.0, data.TERM), "half_borrowed": (0.5, data.TERM), "half_none_back": (0.5, NEVER),
          "three_quarters_borrowed": (0.25, data.TERM)}
NO_RATE = np.zeros(2)  # what the loans pay is counted in lending.py, not here


def ticks(w):
    return float(round(2.0 * np.log(1.0 + w) / np.log(1.0001)))


def run(W, f, w, B, state):
    """Sums over the weeks: volume, filled whole, within 1 and 5 bps of the live pool's fill, swaps, swaps as good."""
    free, term = STATES[state]
    kf = np.array([free, free])
    tot = np.zeros(8)
    stock = money = 0.0
    for x in W:
        u = x["ushare"]
        f0 = min(1.0, 1.5 * f * u / (1.0 - u))  # the stock kept in the pool: 1.5 times the USDG float's dollars
        stock += f0 * x["K"]
        money += x["K"]
        o = core(x["t"], x["d"], x["A"], x["O"], x["f"], x["p0"], x["T"], x["q"], x["sig"], x["usd"], x["K"], u, np.array([f0, f]), 0.0, ticks(w), LIM,
                 LIM, BOTH, kf, NO_RATE, term, 1, 0, 1, 0, 0.0, B, 0.05, 1, 0)
        tot += np.array([o[37], o[30], o[31], o[32], o[27], o[35], o[38] * len(x["T"]), len(x["T"])])
    v = max(tot[0], 1e-12)
    return dict(other_float=stock / money, whole=tot[1] / v, same_1bp=tot[2] / v, same_5bp=tot[3] / v, swaps_same=tot[5] / max(tot[4], 1),
                in_band=tot[6] / max(tot[7], 1))


def main(name):
    W = data.weeks(name)
    b = data.POOLS[name]
    swaps = sum(len(x["t"]) for x in W)
    money = sum(x["K"] for x in W) / len(W)
    ushare = sum(x["K"] * x["ushare"] for x in W) / sum(x["K"] for x in W)
    rows, best = [], {}
    for f in FLOATS:
        for state in ("nothing_borrowed", "half_borrowed"):
            top = None
            for w, B in SHAPES:
                r = run(W, f, w, B, state)
                r.update(pool=name, state=state, usdg_float=f, range=w, band=B, picked=0)
                rows.append(r)
                if top is None or r["same_5bp"] + r["whole"] > top["same_5bp"] + top["whole"]:
                    top = r
            top["picked"] = 1
            best[(f, state)] = top
        h = best[(f, "half_borrowed")]
        for state in ("half_none_back", "three_quarters_borrowed"):
            r = run(W, f, h["range"], h["band"], state)
            r.update(pool=name, state=state, usdg_float=f, range=h["range"], band=h["band"], picked=1)
            rows.append(r)
            best[(f, state)] = r
    os.makedirs(f"{HERE}/results", exist_ok=True)
    with open(f"{HERE}/results/floatfit_{name}.csv", "w", newline="") as fh:
        w_ = csv.DictWriter(fh, fieldnames=["pool", "state", "usdg_float", "other_float", "range", "band", "picked", "whole", "same_1bp", "same_5bp",
                                            "swaps_same", "in_band"])
        w_.writeheader()
        w_.writerows(rows)
    K = b["usdg"] + b["other_usd"]
    L = [f"**{name.upper()}/USDG** ({swaps:,} swaps over {len(W)} weeks. The pool held ${money / 1e3:,.0f}k on average, {ushare * 100:.0f}% of it USDG; "
         f"${K / 1e3:,.0f}k and {b['usdg'] / K * 100:.0f}% at the snapshot.)\n",
         "| USDG in the pool | Stock in the pool | Range | Band | Filled whole | Within 5 bps of the live pool: nothing borrowed | Half borrowed | Half, none back inside a week | Three quarters borrowed |",
         "|---|---|---|---|---|---|---|---|---|"]
    for f in FLOATS:
        h = best[(f, "half_borrowed")]
        a = next(r for r in rows if r["state"] == "nothing_borrowed" and r["usdg_float"] == f and (r["range"], r["band"]) == (h["range"], h["band"]))
        n, q = best[(f, "half_none_back")], best[(f, "three_quarters_borrowed")]
        L.append(f"| {f * 100:g}% | {h['other_float'] * 100:.1f}% | ±{h['range'] * 100:g}% | ±{h['band'] * 100:g}% | {h['whole'] * 100:.1f}% | "
                 f"{a['same_5bp'] * 100:.1f}% | {h['same_5bp'] * 100:.1f}% | {n['same_5bp'] * 100:.1f}% | {q['same_5bp'] * 100:.1f}% |")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    names = sys.argv[1:] or NAMES
    out = [main(n) for n in names]
    print("\n".join(out))
    if names == NAMES:
        open(f"{HERE}/results/floatfit.md", "w").write("\n".join(out))
