"""Stock/USDG pools in one shape (X = the stock, price p = USDG per X, human units) and the keeper-pass grid with a
stand-in for the signed price at each pass (the median of exchange 5-minute closes of the tokenized stock)."""
import json
import math
import os

import numpy as np

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
BT = np.array(json.load(open(f"{DATA}/blocktimes.json")), float)
PASS = 300
WEEK = 7 * 86400.0
TERM = 14 * 86400.0
# The pool's money at the snapshot block (USDG, and the stock in dollars), and how its swap log reads:
# x0 = the stock is the pool's currency0; dx, du = the stock's and USDG's decimals.
SNAPSHOT = json.load(open(f"{DATA}/pools.json"))
POOLS = SNAPSHOT["pools"]
# What each pool really held week by week: `end` is the week's last keeper pass (unix time), `money` the dollars of
# all its positions and `usdg_share` the USDG's part, each the mean of one reading a day. Summed from the pool's
# liquidity events, every position at the pool's price at the reading.
HOLDINGS = json.load(open(f"{DATA}/holdings_weekly.json"))

_cache = {}


def load(name):
    if name in _cache:
        return _cache[name]
    c = POOLS[name]
    z = np.load(f"{DATA}/{name}_usdg.npz")
    t = np.interp(z["block"].astype(float), BT[:, 0], BT[:, 1])
    sq, a0, a1 = z["sqrtP"], z["a0"], z["a1"]
    sgn = -1.0  # v4 deltas are the swapper's: negative = paid in
    if c["x0"]:
        p = sq**2 * 10 ** (c["dx"] - c["du"])
        xin, uin = sgn * a0 / 10 ** c["dx"], sgn * a1 / 10 ** c["du"]
    else:
        p = 10 ** (c["dx"] - c["du"]) / sq**2
        uin, xin = sgn * a0 / 10 ** c["du"], sgn * a1 / 10 ** c["dx"]
    p0 = np.concatenate([[p[0]], p[:-1]])
    # xin, uin: what the swap paid into the pool (negative = what it took out), fee included
    out = dict(t=t, p=p, p0=p0, fee=z["fee"] / 1e6, sell=xin > 0, xin=xin, uin=uin)
    _cache[name] = out
    return out


def prep(name):
    m = load(name)
    t, p = m["t"], m["p"]
    T = np.arange(math.ceil((t[0] + 3600) / PASS) * PASS, t[-1], PASS, dtype=float)
    mkt = p[np.searchsorted(t, T, side="right") - 1]
    z = np.load(f"{DATA}/{name}_usdg_ref.npz")
    assert np.array_equal(z["T"], T), "the pass grid moved"
    return dict(T=T, m=mkt, ref=z["ref"], **m)


def weeks(name):
    """The window cut into weeks, newest first: each with its swaps, its passes, and the money and the share of USDG
    the live pool held that week."""
    d = prep(name)
    held = {round(h["end"]): h for h in HOLDINGS[name]}
    ref0 = d["m"][0]
    t, T = d["t"], d["T"]
    out = []
    end = T[-1]
    while end - WEEK >= T[0]:
        kp = (T >= end - WEEK) & (T < end)
        Tw = T[kp]
        ks = (t >= Tw[0]) & (t < Tw[-1] + PASS)
        if ks.sum() >= 50:
            h = held[round(float(Tw[-1]))]
            sell = d["sell"][ks]
            A = np.abs(np.where(sell, d["xin"][ks] * ref0, d["uin"][ks]))
            O = np.where(sell, -d["uin"][ks], -d["xin"][ks] * ref0)
            out.append(dict(t=t[ks], d=np.where(sell, 0, 1).astype(np.int64), A=A, O=O, f=d["fee"][ks], p0=d["p0"][ks] / ref0, T=Tw,
                            q=d["m"][kp] / ref0, sig=d["ref"][kp] / ref0, usd=np.ones(len(Tw)), K=h["money"], ushare=h["usdg_share"]))
        end -= WEEK
    return out
