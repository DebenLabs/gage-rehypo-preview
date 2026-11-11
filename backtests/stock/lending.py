"""Stock pairs: what lending adds for LPs a year, with half or all of the money out of the pool borrowed.

Reads results/floatfit_<pool>.csv. For each share of the USDG kept in the pool it takes the same pick as run.py (the
`least` layout's best shape), then counts, on the whole position and before the vault's fee:

  reserve    the USDG out of the pool that nobody borrows, at what the USDG vault's reserve pays
  fixed cost what borrowers pay on the borrowed share of the USDG and the stock out of the pool

The fixed cost is the mean of gage's 7- and 21-day loan quotes against each stock on 11 November 2026 (gage.cash/rates).
Rewards are left out.

Usage: python3 lending.py  -> results/lending.csv, results/lending.md
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RESERVE = 4.09  # % a year
QUOTES = {"nvda": 9.8, "tsla": 10.0, "spy": 5.2, "gld": 4.8}  # % a year
FLOATS = (0.10, 0.20, 0.25, 0.35, 0.50, 0.60)


def pick(rows, f):
    top = None
    for r in rows:
        if abs(float(r["usdg_float"]) - f) < 1e-9 and r["layout"] == "least":
            v = float(r["same_5bp"]) + float(r["whole"])
            if top is None or v > top[0]:
                top = (v, r)
    return top[1]


def main():
    out, L = [], []
    for name, rate in QUOTES.items():
        rows = list(csv.DictReader(open(f"{HERE}/results/floatfit_{name}.csv")))
        ratio = float(pick(rows, 0.10)["other_float"]) / (1.5 * 0.10)  # USDG dollars over the stock's
        u = ratio / (1 + ratio)  # USDG's share of the pool's money
        L += [f"**{name.upper()}/USDG** (borrowers pay {rate:g}% a year)\n",
              "| USDG in the pool | Stock in the pool | Out of the pool | Within 5 bps of the live pool | Added a year, half borrowed | Added a year, all borrowed |",
              "|---|---|---|---|---|---|"]
        for f in FLOATS:
            r = pick(rows, f)
            U, S = (1 - f) * u, (1 - float(r["other_float"])) * (1 - u)
            half = 0.5 * U * RESERVE + 0.5 * (U + S) * rate
            full = (U + S) * rate
            out.append(dict(pool=name, usdg_float=f, other_float=float(r["other_float"]), out_of_pool=U + S,
                            same_5bp=float(r["same_5bp"]), half_reserve=0.5 * U * RESERVE, half_fixed=0.5 * (U + S) * rate,
                            half=half, full=full))
            L.append(f"| {f * 100:g}% | {float(r['other_float']) * 100:.1f}% | {(U + S) * 100:.0f}% | {float(r['same_5bp']) * 100:.1f}% | "
                     f"{half:.1f}% | {full:.1f}% |")
        L.append("")
    with open(f"{HERE}/results/lending.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)
    open(f"{HERE}/results/lending.md", "w").write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    main()
