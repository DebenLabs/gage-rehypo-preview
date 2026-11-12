"""Stock pairs: what lending adds for LPs a year, with half of the money out of the pool borrowed.

Reads results/floatfit_<pool>.csv and data/pools.json. For each share of the USDG kept in the pool it counts, on the
whole position at the snapshot's holdings, a year, after the vault's fees:

  nothing borrowed  the USDG out of the pool, all of it in the USDG vault's reserve
  USDG side         half of the USDG out of the pool at what borrowers pay, the other half in the reserve
  stock side        half of the stock out of the pool at the same fixed cost, the other half idle: a stock vault has
                    no reserve. A what-if: borrowing a stock token needs a lend generation for it, and on 12 November
                    2026 gage had one for GLD and NVDA, none for SPY, CRCL or TSLA.

What borrowers pay is the mean of gage's 7- and 21-day USDG loan quotes against each stock on 12 November 2026
(gage.cash/rates), as a yearly rate. A vault's fees come first: with an execution fee of up to 12% of the fixed cost and a
performance fee of 6.5% of the rest, the settings of a live partner vault that lends against stocks, depositors keep
82%. Rewards are left out.

The pick is the least USDG float that keeps nine tenths of the volume the same pool fills within 5 bps of the live pool
with nothing lent.

Usage: python3 lending.py  -> results/lending.csv, results/lending.md
"""
import csv
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RESERVE = 4.02  # % a year: the USDG reserve's 7-day rate on 12 November 2026
KEPT = (1 - 0.12) * (1 - 0.065)  # the share of a borrower's fixed cost that reaches depositors
QUOTES = {"gld": (4.17, 3.93), "spy": (4.10, 3.88), "nvda": (7.87, 8.34), "crcl": (4.27, 5.65), "tsla": (6.45, 8.76)}  # % a year: 7 days, 21 days
STOCK_GENERATION = {"gld": True, "spy": False, "nvda": True, "crcl": False, "tsla": False}
FLOATS = (0.10, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60, 0.75, 1.00)
KEEP = 0.90


def money(v):
    return f"${v / 1e3:,.1f}k" if v < 999500 else f"${v / 1e6:,.2f}M"


def main():
    pools = json.load(open(f"{HERE}/data/pools.json"))["pools"]
    out, L = [], []
    for name, quotes in QUOTES.items():
        rate = sum(quotes) / 2
        rows = [r for r in csv.DictReader(open(f"{HERE}/results/floatfit_{name}.csv")) if r["picked"] == "1"]

        def par(state, f):
            return float(next(r for r in rows if r["state"] == state and abs(float(r["usdg_float"]) - f) < 1e-9)["same_5bp"])

        U, S = pools[name]["usdg"], pools[name]["other_usd"]
        K = U + S
        base = par("half_borrowed", 1.0)
        pick = next((f for f in FLOATS if f < 1.0 and par("half_borrowed", f) >= KEEP * base), 1.0)
        L += [f"**{name.upper()}/USDG** (${K / 1e3:,.0f}k at the snapshot, {U / K * 100:.0f}% of it USDG. Borrowers pay {rate:.1f}% a year. "
              + ("A lend generation for the stock exists." if STOCK_GENERATION[name] else "No lend generation for the stock: the last column is a what-if.") + ")\n",
              "| USDG in the pool | Stock in the pool | Out of the pool: USDG / stock | Within 5 bps of the live pool, half borrowed | Added a year: nothing borrowed | Half borrowed, USDG side | Stock side too |",
              "|---|---|---|---|---|---|---|"]
        for f in FLOATS:
            fs = min(1.0, 1.5 * f * U / S)  # stock worth 1.5 times the USDG kept, at the snapshot's split
            ou, os_ = U * (1 - f), S * (1 - fs)
            idle = ou * RESERVE / K
            usdg = (ou / 2 * rate * KEPT + ou / 2 * RESERVE) / K
            stock = os_ / 2 * rate * KEPT / K
            p = par("half_borrowed", f)
            out.append(dict(pool=name, usdg_float=f, stock_float=fs, out_usdg=ou, out_stock=os_, same_5bp_half_borrowed=p, nothing_borrowed=idle,
                            half_usdg_side=usdg, half_stock_side=stock, stock_generation=int(STOCK_GENERATION[name]), pick=int(f == pick)))
            L.append(f"| {f * 100:g}%{' **(pick)**' if f == pick else ''} | {fs * 100:.1f}% | {money(ou)} / {money(os_)} | {p * 100:.1f}% | {idle:.2f}% | "
                     f"{usdg:.2f}% | {usdg + stock:.2f}% |")
        L.append("")
    with open(f"{HERE}/results/lending.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)
    open(f"{HERE}/results/lending.md", "w").write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    main()
