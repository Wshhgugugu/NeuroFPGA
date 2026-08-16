#!/usr/bin/env python3
"""compare_output.py — RTL 输出 vs 黄金参考 对比.

  像素级 (滤波器/幅值等):  --mode pix --tol 1
  边缘图 (最终 Canny):    --mode f1  --f1-min 0.98

用法:
  python scripts/compare_output.py --golden sim/reference/golden_output.hex \
      --rtl out/rtl_output.hex --mode f1 --f1-min 0.98
"""
import argparse
from pathlib import Path


def read_hex(path):
    return [int(t, 16) for t in Path(path).read_text().split()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--rtl", required=True)
    ap.add_argument("--mode", default="pix", choices=["pix", "f1"])
    ap.add_argument("--tol", type=int, default=1)
    ap.add_argument("--f1-min", type=float, default=0.98)
    ap.add_argument("--max-report", type=int, default=20)
    args = ap.parse_args()

    g = read_hex(args.golden)
    r = read_hex(args.rtl)
    if len(g) != len(r):
        print(f"FAIL: length mismatch golden={len(g)} rtl={len(r)}")
        raise SystemExit(1)

    if args.mode == "pix":
        bad = [(i, g[i], r[i]) for i in range(len(g))
               if abs(g[i] - r[i]) > args.tol]
        if not bad:
            print(f"PASS: {len(g)} pixels, max-tol {args.tol}")
        else:
            print(f"FAIL: {len(bad)}/{len(g)} pixels exceed tol {args.tol}:")
            for i, gv, rv in bad[:args.max_report]:
                print(f"  [{i:6d}] golden={gv} rtl={rv} diff={rv-gv}")
            raise SystemExit(1)
    else:  # f1
        gb = [v != 0 for v in g]
        rb = [v != 0 for v in r]
        tp = sum(1 for a, b in zip(gb, rb) if a and b)
        fp = sum(1 for a, b in zip(gb, rb) if not a and b)
        fn = sum(1 for a, b in zip(gb, rb) if a and not b)
        prec = tp / (tp + fp) if tp + fp else 1.0
        rec = tp / (tp + fn) if tp + fn else 1.0
        f1 = 2 * prec * rec / (prec + rec) if prec + rec else 1.0
        print(f"TP={tp} FP={fp} FN={fn}  precision={prec:.4f} recall={rec:.4f} F1={f1:.4f}")
        if f1 < args.f1_min:
            print(f"FAIL: F1 {f1:.4f} < {args.f1_min}")
            raise SystemExit(1)
        print(f"PASS: F1 {f1:.4f} >= {args.f1_min}")


if __name__ == "__main__":
    main()
