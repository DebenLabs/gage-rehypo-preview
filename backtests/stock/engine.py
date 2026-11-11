"""A model of the rehypo source and the kit's anchored hook, replaying a stock pair's real swaps.

Beyond the stable engine: a float per side (phi[0], phi[1]), the pool's real split of USDG (ushare), each real
swap's own output (O) beside what this pool would pay for it from the same price, and for a priced source a band
width (Bw), a centre clamp (CMh), the cap inside the band (capmode) and a what-if failsafe room (room).

Switches kept from the study: payrule 0 drops the ask-pays test; drawrule 1 lets an anchored range ask on any
swap, re-sized after a draw; drawrule 2 is a one-sided draw; frate pays a plain vault's free cash.

Pegged sources as published, beside parity sources, with explicit arbitrage.

The rehypo pool keeps its own price P. Arbitrage trades it back toward the local market price (the live pool) whenever
the gap is more than the fee: before every real swap and after every keeper pass. Those trades go through the pool's
JIT liquidity, so a pool centred away from the local price pays for it: income here is the LP's value against holding,
valued at the local price, so fees, lending and every loss to arbitrage are in it.

Pegged: the range and band centre on the signed price at each keeper move (clamp 100 bps an hour, band
+-0.5%); a move reverts while the signed price is more than 0.5% from $1 (no refill, sweep, centre move or reopen);
inside the band the whole float is open (swapCap max), past it the declared range's past-band cap; failsafe room is
failsafeBps of the backing. Optional keeper check (`lcheck`): no move while the local price is more than 0.25% from the
signed price. Parity: centre 1, band +-0.5%, `_inBandCap` for a declared range, failsafe room 0 on it.
Hooks: the kit's anchored hooks (full range until both sources hold a cap; anchored sizing at the centre on the first swap
after a move, then held). Failsafe ask (FailsafeUnlockCheckedHook as built): every real swap, exact input estimated at
the pool price, only when it would take more than half of what the output side backs, can at its limit, the ask pays
(fee x ask/2 >= ask x 10 pips + $0.10), and on an anchored range only on fresh sizing.
"""
import math

import numpy as np
from numba import njit

YEAR = 365 * 86400.0
CONC = 40003.0
B = 0.005
PEG = 0.005
CLAMP = 0.01  # 100 bps an hour
LCHECK = 0.0025
FORGONE = 10e-6
MIN_DRAW = 0.10
BIG = 1e300


@njit(cache=True)
def band_ticks(lo, hi):
    return math.floor((math.sqrt(hi / lo) - 1.0) * 20001.0) + 1.0


@njit(cache=True)
def in_band_cap(target, R, w):
    rc = R * CONC
    rpc = R + CONC
    if rc > w * rpc:
        rnd = target * 100.0 * rc / (16.0 * w * w * rpc)
    else:
        rnd = target * 100.0 / (16.0 * w)
    stretch = target * 100.0 * rc / (5.0 * w * w * rpc)
    return min(target, min(rnd, stretch))


@njit(cache=True)
def past_band_cap(target, P, lo, hi):
    r = P / lo if P < lo else hi / P
    return target * 0.01 * r * r


@njit(cache=True)
def liq_oz(sx, sy, s0, R, sa, sb):
    if sx <= 0.0 or sy <= 0.0:
        return 0.0
    if R == 0:
        return min(sx * s0, sy / s0)
    if s0 <= sa:
        return sx / (1.0 / sa - 1.0 / sb)
    if s0 >= sb:
        return sy / (sb - sa)
    return min(sx / (1.0 / s0 - 1.0 / sb), sy / (s0 - sa))


@njit(cache=True)
def liq_anchor(sx, sy, s0, R, sa, sb, a):
    L = liq_oz(sx, sy, s0, R, sa, sb)
    if R == 0 or L <= 0.0:
        return L
    a = min(max(a, sa), sb)
    if a < sb:
        L = min(L, sx / (1.0 / a - 1.0 / sb))
    if a > sa:
        L = min(L, sy / (a - sa))
    return L


@njit(cache=True)
def move(L, d, sP, st, R, sa, sb, f, maxin):
    """Trade from sqrt price sP toward st (d 0: price falls) through liquidity L on [sa, sb] (full range if R == 0), at
    most `maxin` gross input. Returns (gross in, out, new sqrt price)."""
    if d == 0:
        if st >= sP:
            return 0.0, 0.0, sP
        hi = sP if R == 0 else min(sP, sb)
        lo = st if R == 0 else max(st, sa)
        if hi <= lo or L <= 0.0:
            return 0.0, 0.0, st if maxin > 0.0 else sP
        cap = L * (1.0 / lo - 1.0 / hi)
        net = min(maxin * (1.0 - f), cap)
        s1 = 1.0 / (1.0 / hi + net / L)
        out = L * (hi - s1)
        end = s1 if net < cap * (1.0 - 1e-12) else st
        return net / (1.0 - f), out, end
    if st <= sP:
        return 0.0, 0.0, sP
    lo = sP if R == 0 else max(sP, sa)
    hi = st if R == 0 else min(st, sb)
    if hi <= lo or L <= 0.0:
        return 0.0, 0.0, st if maxin > 0.0 else sP
    cap = L * (hi - lo)
    net = min(maxin * (1.0 - f), cap)
    s1 = lo + net / L
    out = L * (1.0 / lo - 1.0 / s1)
    end = s1 if net < cap * (1.0 - 1e-12) else st
    return net / (1.0 - f), out, end


@njit(cache=True)
def liq_now(F, SF, C, P, R, sa, sb, sc, held, fresh_needed):
    """(L, Reff, fresh) for a swap at pool price P (the kit's anchored hook)."""
    capped = C[0] != 0.0 and C[1] != 0.0
    Re = R if (R > 0 and capped) else 0.0
    sP = math.sqrt(P)
    if Re > 0 and held > 0.0 and not fresh_needed:
        return min(liq_oz(min(F[0], SF[0]), min(F[1], SF[1]), sP, Re, sa, sb), held), Re, False
    return liq_anchor(min(F[0], SF[0]), min(F[1], SF[1]), sP, Re, sa, sb, sc), Re, True


@njit(cache=True)
def settle(F, SF, C, di, gin, out):
    """A swap's input joins the float and the swap float (up to swapCap); its output leaves both."""
    o = 1 - di
    F[di] += gin
    nx = SF[di] + gin
    SF[di] = nx if (C[di] == 0.0 or nx <= C[di]) else max(C[di], SF[di])
    F[o] = max(F[o] - out, 0.0)
    SF[o] = max(SF[o] - out, 0.0)


@njit(cache=True)
def arb(pl, P, F, SF, C, R, sa, sb, sc, held, fresh_needed, fee_dir):
    """Arbitrage the pool from P back to within the fee of the local price pl. Returns
    (P, held, fresh_needed, fees, volume, LP gain at pl)."""
    fees = 0.0
    vol = 0.0
    pnl = 0.0
    for dd in range(2):
        fa = fee_dir[dd]
        if dd == 0 and P > pl * (1.0 + fa):
            st = math.sqrt(pl * (1.0 + fa))
        elif dd == 1 and P < pl / (1.0 + fa):
            st = math.sqrt(pl / (1.0 + fa))
        else:
            continue
        L, Re, fr = liq_now(F, SF, C, P, R, sa, sb, sc, held, fresh_needed)
        gin, out, s1 = move(L, dd, math.sqrt(P), st, Re, sa, sb, fa, 1e300)
        if gin > 0.0:
            held = L
            fresh_needed = False
            settle(F, SF, C, dd, gin, out)
            if dd == 0:
                fees += gin * fa * pl
                vol += gin * pl
                pnl += gin * pl - out
            else:
                fees += gin * fa
                vol += gin
                pnl += gin - out * pl
        P = s1 * s1
    return P, held, fresh_needed, fees, vol, pnl


@njit(cache=True)
def core(t, d, A, O, f, p0, T, q, sig, usd, K, ushare, phi, fs, R, tau, lim, vmode, kfree, rate, term, pegged, lcheck, payrule, drawrule, frate, Bw, CMh, capmode, room):
    n = t.shape[0]
    nP = T.shape[0]
    F = np.zeros(2)
    V = np.zeros(2)
    Fv = np.zeros(2)
    Lv = np.zeros(2)
    SF = np.zeros(2)
    C = np.zeros(2)
    FL = np.zeros(2)
    P = q[0]
    side0 = K * (1.0 - ushare) / P
    side1 = K * ushare
    for s in range(2):
        tot = side0 if s == 0 else side1
        F[s] = phi[s] * tot
        V[s] = tot - F[s]
        if vmode[s] == 0:
            Fv[s] = V[s]
        else:
            Fv[s] = kfree[s] * V[s]
            Lv[s] = V[s] - Fv[s]
    c = 1.0
    cAt = T[0]
    centred = False
    lo = c * (1.0 - Bw)
    hi = c * (1.0 + Bw)
    inb_last = False
    held = 0.0
    fresh_needed = True
    fee_dir = np.array([np.median(f[d == 0]) if np.any(d == 0) else 0.0005,
                        np.median(f[d == 1]) if np.any(d == 1) else 0.0005])
    # accumulators
    vol = 0.0
    filled = 0.0
    fs_fill = 0.0
    fees = 0.0
    lend = 0.0
    arb_vol = 0.0
    arb_pnl = 0.0
    real_pnl = 0.0
    skipped = 0
    offpeg = 0
    moves = 0
    draws = 0
    drawn = 0.0
    draw_fee = 0.0
    draw_cost = 0.0
    draws_paid = 0
    dr_side = np.zeros(2 * n + 2, np.int64)
    dr_amt = np.zeros(2 * n + 2)
    dr_t = np.zeros(2 * n + 2)
    dr_fee = np.zeros(2 * n + 2)
    dr_open = np.zeros(2 * n + 2, np.bool_)
    nd = 0
    n_full = 0
    stopped = 0
    why_reopen = 0
    why_centre = 0
    n_past = 0
    fl_sum = 0.0
    sf_sum = 0.0
    tot_sum = 0.0
    sa = 0.0
    sb = 0.0
    sc = 1.0
    Xp = 0.0
    Up = 0.0
    tr5 = 0.0
    tr60 = 0.0
    par_full = 0.0
    par_1 = 0.0
    par_5 = 0.0
    par_10 = 0.0
    par_gap = 0.0
    par_vol = 0.0
    n_par = 0
    v1_sum = 0.0
    tot1_sum = 0.0
    n_in = 0
    i = 0
    while i < n and t[i] < T[0]:
        i += 1
    for k in range(nP):
        dt = T[k] - T[k - 1] if k > 0 else 0.0
        if k > 0:
            dX = F[0] + V[0] - Xp
            dU = F[1] + V[1] - Up
            tr5 += dX * q[k] + dU
            tr60 += dX * q[min(k + 11, nP - 1)] + dU
        for s in range(2):
            if dt > 0.0:
                if vmode[s] == 0:
                    g = V[s] * rate[s] * dt / YEAR
                    V[s] += g
                    Fv[s] = V[s]
                else:
                    g = Lv[s] * rate[s] * dt / YEAR
                    Lv[s] += g
                    gf = Fv[s] * frate * dt / YEAR
                    Fv[s] += gf
                    g += gf
                    rep = Lv[s] * dt / term
                    Lv[s] -= rep
                    Fv[s] += rep
                    keep = kfree[s] * (Fv[s] + Lv[s])
                    if Fv[s] > keep:
                        Lv[s] += Fv[s] - keep
                        Fv[s] = keep
                    V[s] = Fv[s] + Lv[s]
                lend += g * (P if s == 0 else 1.0)
        Xp = F[0] + V[0]
        Up = F[1] + V[1]
        # failsafe draws left in the float: their idle time ends at this pass
        for j in range(nd):
            if dr_open[j]:
                cost = dr_amt[j] * rate[dr_side[j]] * (T[k] - dr_t[j]) / YEAR
                draw_cost += cost
                if dr_fee[j] >= cost + MIN_DRAW:
                    draws_paid += 1
                dr_open[j] = False
        if capmode == 1 and k > 0:
            P, held, fresh_needed, a1, a2, a3 = arb(q[k], P, F, SF, C, R, sa, sb, sc, held, fresh_needed, fee_dir)
            fees += a1
            arb_vol += a2
            arb_pnl += a3
        # the keeper
        allow = True
        r = sig[k] if pegged else 1.0
        if pegged:
            if abs(usd[k] - 1.0) > PEG:
                allow = False
                offpeg += 1
            elif lcheck and abs(q[k] / r - 1.0) > LCHECK:
                allow = False
                skipped += 1
        due = False
        for s in range(2):
            target = phi[s] * (F[s] + V[s])
            free = V[s] if vmode[s] == 0 else min(Fv[s], V[s])
            if F[s] > target and F[s] - target >= 1.0 and (F[s] * 2.0 > target * 3.0 or SF[s] > target):
                due = True
            if F[s] < target and F[s] * 2.0 < target and min(target - F[s], free) >= 1.0:
                due = True
            opens = min(F[s], target)
            if R > 0 and (not pegged or capmode == 1) and inb_last:
                opens = min(opens, in_band_cap(target, R, band_ticks(lo, hi)))
            if SF[s] * 2.0 < opens and opens >= 1.0:
                due = True
                why_reopen += 1
        if pegged and (capmode == 1 or not centred or abs(r / c - 1.0) >= Bw / 2.0):
            due = True
            why_centre += 1
        if allow and due:
            moves += 1
            if pegged:
                if not centred:
                    c = r
                    centred = True
                else:
                    Fm = 1.0 + CMh * (T[k] - cAt) / 3600.0
                    c = min(max(r, c / Fm), c * Fm)
                cAt = T[k]
            lo = c * (1.0 - Bw)
            hi = c * (1.0 + Bw)
            w = band_ticks(lo, hi)
            past = P < lo or P > hi
            if past:
                n_past += 1
            for s in range(2):
                target = phi[s] * (F[s] + V[s])
                if F[s] > target:
                    sw = F[s] - target
                    if sw >= 1.0:
                        F[s] -= sw
                        V[s] += sw
                        if vmode[s] == 0:
                            Fv[s] = V[s]
                        else:
                            Fv[s] += sw
                            keep = kfree[s] * V[s]
                            if Fv[s] > keep:
                                Lv[s] += Fv[s] - keep
                                Fv[s] = keep
                elif F[s] < target:
                    free = V[s] if vmode[s] == 0 else min(Fv[s], V[s])
                    rf = min(target - F[s], free)
                    if rf > 0.0:
                        F[s] += rf
                        V[s] -= rf
                        if vmode[s] == 0:
                            Fv[s] = V[s]
                        else:
                            Fv[s] -= rf
                depth = min(F[s], target)
                if past:
                    cap = past_band_cap(target, P, lo, hi)
                    cap = max(cap, SF[s]) if R == 0 else cap * R / (R + CONC)
                    depth = min(depth, cap)
                    ceiling = 0.0
                else:
                    ceiling = BIG if (R == 0 or (pegged and capmode == 0)) else in_band_cap(target, R, w)
                    depth = min(depth, ceiling)
                SF[s] = depth
                FL[s] = min(fs * (F[s] + V[s]), ceiling - depth) if (fs > 0.0 and not past) else 0.0
                if room == 1 and fs > 0.0 and not past:
                    FL[s] = fs * (F[s] + V[s])
                    ceiling = ceiling + FL[s]
                C[s] = ceiling
            inb_last = not past
            fresh_needed = True
        if min(F[0], SF[0]) < 1.0 or min(F[1], SF[1]) < 1.0:
            stopped += 1
        fl_sum += F[0] * P + F[1]
        sf_sum += min(F[0], SF[0]) * P + min(F[1], SF[1])
        tot_sum += (F[0] + V[0]) * P + F[1] + V[1]
        v1_sum += V[1]
        tot1_sum += F[1] + V[1]
        if inb_last:
            n_in += 1
        # the range now
        sc = math.sqrt(c)
        lower = -math.floor(R / 2.0)
        sa = sc * 1.0001 ** (lower / 2.0)
        sb = sc * 1.0001 ** ((lower + R) / 2.0)
        Tn = T[k + 1] if k + 1 < nP else 1e300
        # arbitrage at this pass, then before every swap until the next one
        P, held, fresh_needed, a1, a2, a3 = arb(q[k], P, F, SF, C, R, sa, sb, sc, held, fresh_needed, fee_dir)
        fees += a1
        arb_vol += a2
        arb_pnl += a3
        while i < n and t[i] < Tn:
            P, held, fresh_needed, a1, a2, a3 = arb(p0[i], P, F, SF, C, R, sa, sb, sc, held, fresh_needed, fee_dir)
            fees += a1
            arb_vol += a2
            arb_pnl += a3
            di = d[i]
            o = 1 - di
            Ai = A[i]
            fi = f[i]
            fee_dir[di] = fi
            vol += Ai
            sP = math.sqrt(P)
            st = math.sqrt(p0[i] * (1.0 - tau)) if di == 0 else math.sqrt(p0[i] * (1.0 + tau))
            L, Re, fresh = liq_now(F, SF, C, P, R, sa, sb, sc, held, fresh_needed)
            g0, o0, e0 = move(L, di, sP, st, Re, sa, sb, fi, Ai)
            drew = False
            Lx = 0.0
            if fs > 0.0 and drawrule == 2:
                # What-if: the hook sizes a draw for the swap's side only. Whatever the float could not fill inside the
                # swap's limit is asked of the vault, and the drawn output token joins the just-in-time position on the
                # swap's side of the price, inside the same anchored range. Any swap may ask.
                need = Ai * (1.0 - fi) * (P if di == 0 else 1.0 / P)
                inside = P >= lo and P <= hi and inb_last and (Re == 0.0 or (sP > sa and sP < sb))
                if g0 < Ai * (1.0 - 1e-9) and need > o0 and inside:
                    ask = need - o0
                    pays = payrule == 0 or fi * ask / 2.0 >= ask * FORGONE + MIN_DRAW
                    if pays:
                        open_ = C[o] - SF[o] if C[o] > SF[o] else 0.0
                        amt = min(ask, min(FL[o], open_))
                        free = V[o] if vmode[o] == 0 else min(Fv[o], V[o])
                        got = min(amt, free)
                        if got > 0.0:
                            FL[o] -= got
                            SF[o] += got
                            F[o] += got
                            V[o] -= got
                            if vmode[o] == 0:
                                Fv[o] = V[o]
                            else:
                                Fv[o] -= got
                            draws += 1
                            drawn += got
                            dr_side[nd] = o
                            dr_amt[nd] = got
                            dr_t[nd] = t[i]
                            dr_open[nd] = True
                            drew = True
                            if Re == 0.0:
                                Lx = got * sP if di == 1 else got / sP
                            elif di == 1:
                                Lx = got / (1.0 / sP - 1.0 / sb)
                                if sc < sb:  # never denser than the drawn token backs at the anchor (the hook's _atAnchor)
                                    Lx = min(Lx, got / (1.0 / sc - 1.0 / sb))
                            else:
                                Lx = got / (sP - sa)
                                if sc > sa:
                                    Lx = min(Lx, got / (sc - sa))
            elif fs > 0.0 and drawrule == 3:
                # What-if: both sides keep cash free, so the draw asks both vaults, each in
                # proportion to its float. The hook's own sizing (from both tokens) then grows; nothing else changes.
                # Any swap the float cannot fill inside its limit may ask, for just what it needs.
                b0 = min(F[0], SF[0])
                b1 = min(F[1], SF[1])
                if g0 > 0.0 and g0 < Ai * (1.0 - 1e-9) and b0 > 0.0 and b1 > 0.0 and P >= lo and P <= hi and inb_last:
                    rho = Ai / g0 - 1.0
                    for s in range(2):
                        open_ = C[s] - SF[s] if C[s] > SF[s] else 0.0
                        free = V[s] if vmode[s] == 0 else min(Fv[s], V[s])
                        rho = min(rho, min(FL[s], min(open_, free)) / (b0 if s == 0 else b1))
                    ask = rho * (b0 if o == 0 else b1)
                    pays = payrule == 0 or fi * ask / 2.0 >= ask * FORGONE + MIN_DRAW
                    if rho > 0.0 and pays:
                        for s in (di, o):  # the output side last: its record takes the swap's extra fee below
                            got = rho * (b0 if s == 0 else b1)
                            FL[s] -= got
                            SF[s] += got
                            F[s] += got
                            V[s] -= got
                            if vmode[s] == 0:
                                Fv[s] = V[s]
                            else:
                                Fv[s] -= got
                            drawn += got
                            dr_side[nd] = s
                            dr_amt[nd] = got
                            dr_t[nd] = t[i]
                            dr_open[nd] = True
                            if s == di:
                                nd += 1
                        draws += 1
                        drew = True
                        L = liq_anchor(min(F[0], SF[0]), min(F[1], SF[1]), sP, Re, sa, sb, sc)
            elif fs > 0.0:
                need = Ai * (1.0 - fi) * (P if di == 0 else 1.0 / P)
                most = min(F[o], SF[o])
                if need * 2.0 > most:
                    gx, ox, ex = move(L, di, sP, st, Re, sa, sb, fi, 1e300)
                    ask = need * 2.0 - most
                    pays = payrule == 0 or fi * ask / 2.0 >= ask * FORGONE + MIN_DRAW
                    if ox * 2.0 > most and pays and (Re == 0.0 or fresh or drawrule == 1) and P >= lo and P <= hi and inb_last:
                        open_ = C[o] - SF[o] if C[o] > SF[o] else 0.0
                        amt = min(ask, min(FL[o], open_))
                        free = V[o] if vmode[o] == 0 else min(Fv[o], V[o])
                        got = min(amt, free)
                        if got > 0.0:
                            FL[o] -= got
                            SF[o] += got
                            F[o] += got
                            V[o] -= got
                            if vmode[o] == 0:
                                Fv[o] = V[o]
                            else:
                                Fv[o] -= got
                            draws += 1
                            drawn += got
                            dr_side[nd] = o
                            dr_amt[nd] = got
                            dr_t[nd] = t[i]
                            dr_open[nd] = True
                            drew = True
                            L = liq_anchor(min(F[0], SF[0]), min(F[1], SF[1]), sP, Re, sa, sb, sc)
            g1, o1, e1 = move(L + Lx, di, sP, st, Re, sa, sb, fi, Ai)
            # The same swap from the venue's own price before it, on this pool's liquidity, no further than `lim`:
            # beside what the venue's pool really paid (O).
            if O[i] > 0.0:
                par_vol += Ai
                sl = math.sqrt(p0[i] * (1.0 - lim)) if di == 0 else math.sqrt(p0[i] * (1.0 + lim))
                gS, oS, eS = move(L + Lx, di, math.sqrt(p0[i]), sl, Re, sa, sb, fi, Ai)
                if gS >= Ai * (1.0 - 1e-9):
                    par_full += Ai
                    gap = oS / O[i] - 1.0
                    par_gap += Ai * gap
                    if gap >= -1e-4:
                        par_1 += Ai
                        n_par += 1
                    if gap >= -5e-4:
                        par_5 += Ai
                    if gap >= -1e-3:
                        par_10 += Ai
            if drew:
                extra = max(g1 - g0, 0.0)
                dr_fee[nd] = extra * fi * (p0[i] if di == 0 else 1.0)
                draw_fee += dr_fee[nd]
                fs_fill += extra
                nd += 1
            if g1 > 0.0:
                held = L
                fresh_needed = False
                settle(F, SF, C, di, g1, o1)
                if di == 0:
                    fees += g1 * fi * p0[i]
                    real_pnl += g1 * p0[i] - o1
                else:
                    fees += g1 * fi
                    real_pnl += g1 - o1 * p0[i]
            filled += g1
            if g1 >= Ai * (1.0 - 1e-9):
                n_full += 1
            P = e1 * e1
            i += 1
    for j in range(nd):
        if dr_open[j]:
            cost = dr_amt[j] * rate[dr_side[j]] * (T[nP - 1] - dr_t[j]) / YEAR
            draw_cost += cost
            if dr_fee[j] >= cost + MIN_DRAW:
                draws_paid += 1
    qe = q[nP - 1]
    tr5 += (F[0] + V[0] - Xp) * qe + F[1] + V[1] - Up
    tr60 += (F[0] + V[0] - Xp) * qe + F[1] + V[1] - Up
    v_end = (F[0] + V[0]) * qe + F[1] + V[1]
    v_hold = side0 * qe + side1
    out = np.zeros(40)
    out[28] = tr5
    out[29] = tr60
    out[25] = fl_sum / tot_sum
    out[26] = sf_sum / tot_sum
    out[27] = n
    out[22] = why_reopen
    out[23] = why_centre
    out[24] = n_past
    out[0] = vol
    out[1] = filled
    out[2] = fs_fill
    out[3] = fees
    out[4] = lend
    out[5] = v_end - v_hold
    out[6] = arb_vol
    out[7] = arb_pnl
    out[8] = real_pnl
    out[9] = skipped / nP
    out[10] = offpeg / nP
    out[11] = moves
    out[12] = draws
    out[13] = drawn
    out[14] = draw_fee
    out[15] = draw_cost
    out[16] = draws_paid
    out[17] = n_full
    out[18] = stopped / nP
    out[19] = F[0] / max(phi[0] * (F[0] + V[0]), 1e-12)
    out[20] = F[1] / max(phi[1] * (F[1] + V[1]), 1e-12)
    out[30] = par_full
    out[31] = par_1
    out[32] = par_5
    out[33] = par_10
    out[34] = par_gap
    out[35] = n_par
    out[36] = v1_sum / max(tot1_sum, 1e-12)
    out[37] = par_vol
    out[38] = n_in / max(nP, 1)
    out[21] = c
    return out
