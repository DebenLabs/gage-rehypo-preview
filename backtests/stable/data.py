"""A stable pair's real swaps, and the keeper-pass grid."""
import json
import math
import os

import numpy as np

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
BT = np.array(json.load(open(f"{DATA}/blocktimes.json")), float)
WINDOW = 60 * 86400  # or the pool's whole life, where that is shorter
PASS = 300
TERM = 14 * 86400.0
SNAPSHOT_BLOCK = 112796665  # 12 November 2026

# coins and held: the pool's two coins in its own order (currency0, currency1), and the dollars of each it held at the
# snapshot block, summed from its liquidity events. ranges: the two declared ranges the run tries, in ticks (full width).
POOLS = {
    "frxusd_usdg": dict(file="frxusd_usdg.npz", d0=18, d1=6, name="frxUSD/USDG", coins=("frxUSD", "USDG"), held=(9558.75, 12423.17), ranges=(50.0, 100.0)),
    "eusd_usdg": dict(file="eusd_usdg.npz", d0=6, d1=18, name="eUSD/USDG", coins=("USDG", "eUSD"), held=(94963.96, 63832.35), ranges=(100.0, 200.0)),
    "frxusd_ausd": dict(file="frxusd_ausd.npz", d0=18, d1=18, name="frxUSD/aUSD", coins=("frxUSD", "aUSD"), held=(104129.02, 176226.88), ranges=(40.0, 100.0)),
}
# Whether gage had a lend generation for the coin on 12 November 2026: without one, the coin out of the pool cannot be lent.
LENDABLE = {"USDG": True, "frxUSD": True, "eUSD": False, "aUSD": False}


def load(key):
    c = POOLS[key]
    z = np.load(f"{DATA}/{c['file']}")
    a0 = -z["a0"] / 10 ** c["d0"]
    a1 = -z["a1"] / 10 ** c["d1"]
    p = z["sqrtP"] ** 2 * 10 ** (c["d0"] - c["d1"])
    p0 = np.concatenate([[p[0]], p[:-1]])
    t = np.interp(z["block"].astype(float), BT[:, 0], BT[:, 1])
    return dict(t=t, p=p, p0=p0, fee=z["fee"] / 1e6, dir=np.where(a0 > 0, 0, 1), size=np.where(a0 > 0, a0, a1))


def prep(key):
    m = load(key)
    t = m["t"]
    t_start = max(t[-1] - WINDOW, t[0])
    T = np.arange(math.ceil(t_start / PASS) * PASS, t[-1], PASS, dtype=float)
    idx = np.searchsorted(t, T, side="right") - 1
    q = np.where(idx >= 0, m["p"][np.clip(idx, 0, None)], m["p0"][0])
    k = t >= T[0]
    return dict(t=t[k], d=m["dir"][k].astype(np.int64), A=m["size"][k], f=m["fee"][k], p0=m["p0"][k], T=T, q=q)
