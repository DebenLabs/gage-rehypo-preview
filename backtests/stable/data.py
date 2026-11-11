"""A stable pair's real swaps and the signed price at each keeper pass."""
import json
import math
import os

import numpy as np

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
BT = np.array(json.load(open(f"{DATA}/blocktimes.json")), float)
WINDOW = 30 * 86400
PASS = 300
RATE_USDG = 0.0409  # what the USDG vault's reserve paid a year on 10 November 2026
BORROW = 0.07  # assumed: what borrowers pay a year on the other stablecoin
TERM = 14 * 86400.0

# side 0 = the pool's currency0; vmode 0 = a USDG vault with a reserve (all of it can be withdrawn), 1 = a plain vault
POOLS = {
    "frxusd_usdg": dict(file="frxusd_usdg.npz", d0=18, d1=6, name="frxUSD/USDG", vmode=(1, 0), today=25e3),
    "eusd_usdg": dict(file="eusd_usdg.npz", d0=6, d1=18, name="eUSD/USDG", vmode=(0, 1), today=100e3),
}


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


def signed(key, T):
    """(signed price in the pool's order, the other coin's price in USDG) at each pass; never from the pool itself."""
    if key == "frxusd_usdg":  # frxUSD over USDG from hourly market prices, read at each pass
        z = np.load(f"{DATA}/frxusd_usdg_signed.npz")
        assert np.array_equal(z["T"], T), "the pass grid moved"
        return z["x"], z["x"]
    return np.ones(len(T)), np.ones(len(T))  # eUSD has no outside price here: a flat $1
