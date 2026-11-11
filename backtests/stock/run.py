"""Stock pairs: which float makes sense per pool.

A rehypo pool, its range centred on the signed price, against every real swap of the live pool over the whole window,
in weekly runs. Each week's pool is given the money the live pool had then (the snapshot's money scaled by that week's
depth at the price). For each share of the USDG kept in the pool: the best of seven range and band shapes, and the
share of volume the pool would have filled whole, and filled within 5 bps of what the live pool really paid.

Two layouts for the stock side: `equal` keeps the same share of the stock in the pool as of the USDG; `least` keeps
stock worth 1.5 times the USDG kept, in dollars.

Usage: python3 run.py [nvda tsla spy gld]  -> results/floatfit_<pool>.csv, results/floatfit.md
"""
import csv
import os
import sys

import numpy as np

import data
from engine import core

HERE = os.path.dirname(os.path.abspath(__file__))
LIM = 0.05
WEEK = 7 * 86400.0
FLOATS = (0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60, 0.75, 1.00)
# range either side, band either side: each band tight enough for the source's cap to open the whole float
SHAPES = [(0.01, 0.0015), (0.02, 0.0025), (0.03, 0.0030), (0.04, 0.0035), (0.06, 0.0040), (0.08, 0.0050), (0.10, 0.0050)]
RESERVE = 0.0409  # what the USDG vault's reserve paid a year on 10 November 2026


def ticks(w):
    return float(round(2.0 * np.log(1.0 + w) / np.log(1.0001)))


def weeks(name):
    """The window cut into weeks, newest first: each with its swaps, passes and the pool's money that week."""
    d = data.prep(name)
    b = data.POOLS[name]
    K = b["usdg"] + b["other_usd"]
    ushare = b["usdg"] / K
    ref0 = d["m"][0]
    t, T = d["t"], d["T"]
    depth = d["L"] * np.sqrt(d["p0"])
    last = np.median(depth[t >= t[-1] - 86400.0])
    out = []
    end = T[-1]
    while end - WEEK >= T[0]:
        kp = (T >= end - WEEK) & (T < end)
        Tw = T[kp]
        ks = (t >= Tw[0]) & (t < Tw[-1] + data.PASS)
        if ks.sum() >= 50:
            sell = d["sell"][ks]
            A = np.abs(np.where(sell, d["xin"][ks] * ref0, d["uin"][ks]))
            O = np.where(sell, -d["uin"][ks], -d["xin"][ks] * ref0)
            out.append(dict(t=t[ks], d=np.where(sell, 0, 1).astype(np.int64), A=A, O=O, f=d["fee"][ks], p0=d["p0"][ks] / ref0, T=Tw,
                            q=d["m"][kp] / ref0, sig=d["ref"][kp] / ref0, usd=np.ones(len(Tw)), K=K * np.median(depth[ks]) / last))
        end -= WEEK
    return out, K, ushare, b


def run(W, ushare, w, B, phi, vm, kf):
    """Sums over the weeks: volume, filled whole, within 1 and 5 bps of the live pool's fill, swaps, swaps as good."""
    tot = np.zeros(8)
    for x in W:
        o = core(x["t"], x["d"], x["A"], x["O"], x["f"], x["p0"], x["T"], x["q"], x["sig"], x["usd"], x["K"], ushare, phi, 0.0, ticks(w), LIM,
                 LIM, vm, kf, np.array([0.0, RESERVE]), data.TERM, 1, 0, 1, 0, 0.0, B, 0.05, 1, 0)
        tot += np.array([o[37], o[30], o[31], o[32], o[27], o[35], o[38] * len(x["T"]), len(x["T"])])
    v = max(tot[0], 1e-12)
    return dict(whole=tot[1] / v, same_1bp=tot[2] / v, same_5bp=tot[3] / v, swaps_same=tot[5] / max(tot[4], 1), in_band=tot[6] / max(tot[7], 1))


def main(name):
    W, K, ushare, b = weeks(name)
    swaps = sum(len(x["t"]) for x in W)
    at_call = (np.array([1, 0], np.int64), np.array([1.0, 0.0]))
    rows, best = [], {}
    for f in FLOATS:
        for layout in ("equal", "least"):
            f0 = f if layout == "equal" else min(1.0, 1.5 * f * b["usdg"] / b["other_usd"])
            top = None
            for w, B in SHAPES:
                r = run(W, ushare, w, B, np.array([f0, f]), *at_call)
                r.update(pool=name, usdg_float=f, other_float=f0, layout=layout, range=w, band=B)
                rows.append(r)
                if top is None or r["same_5bp"] + r["whole"] > top["same_5bp"] + top["whole"]:
                    top = r
            best[(f, layout)] = top
    os.makedirs(f"{HERE}/results", exist_ok=True)
    with open(f"{HERE}/results/floatfit_{name}.csv", "w", newline="") as fh:
        w_ = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w_.writeheader()
        w_.writerows(rows)
    L = [f"**{name.upper()}/USDG** ({swaps:,} swaps over {len(W)} weeks; USDG is {ushare * 100:.0f}% of the pool's money)\n",
         "| USDG in the pool | Stock in the pool | Range | Band | Filled whole | Within 5 bps of the live pool | Same pool, equal shares: within 5 bps |",
         "|---|---|---|---|---|---|---|"]
    for f in FLOATS:
        e, l = best[(f, "equal")], best[(f, "least")]
        L.append(f"| {f * 100:g}% | {l['other_float'] * 100:.1f}% | ±{l['range'] * 100:g}% | ±{l['band'] * 100:g}% | {l['whole'] * 100:.1f}% | "
                 f"{l['same_5bp'] * 100:.1f}% | {e['same_5bp'] * 100:.1f}% |")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    names = sys.argv[1:] or ["nvda", "tsla", "spy", "gld"]
    out = [main(n) for n in names]
    print("\n".join(out))
    if len(names) == 4:
        open(f"{HERE}/results/floatfit.md", "w").write("\n".join(out))
