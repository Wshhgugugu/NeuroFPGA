#!/usr/bin/env python3
"""golden_model_snn.py — SNN 黄金参考 (定点逐位镜像 rtl/snn/*)

冻结规范:
  编码: spike[j][t] = (t < act[j])          (确定性 PWM, TSTEPS 步)
  每步每神经元 n:
    I_raw = Σ_j w8[n][j] * spike[j][t]
    v = v - (v >> 4 算术) + (I_raw << 10)   (Q8.16)
    不应期(REFRA=2 步): 只做 v -= v>>4
    v >= VTH -> spike, v = 0
    饱和: v ∈ [-128<<16, 127<<16]

用法:
  python scripts/golden_model_snn.py --act sim/stimulus/act_64.hex \
      --weights mem/weights_snn.hex --out out/golden_snn.hex --steps 64
"""
import argparse
from pathlib import Path

VTH_DEFAULT = 8 << 16
LEAK = 4
REFRA = 2
VMAX = 127 << 16
VMIN = -128 << 16


def s16(v):
    return v - 256 if v > 127 else v


def run(act, w, nneu, nin, tsteps, vth=VTH_DEFAULT):
    v = [0] * nneu
    refra = [0] * nneu
    cnt = [0] * nneu
    raster = []
    for t in range(tsteps):
        spikes = [1 if t < act[j] else 0 for j in range(nin)]
        fired = []
        for n in range(nneu):
            if refra[n] > 0:
                refra[n] -= 1
                v[n] = max(VMIN, min(VMAX, v[n] - (v[n] >> LEAK)))
                continue
            i_raw = sum(s16(w[n * nin + j]) * spikes[j] for j in range(nin))
            vnext = v[n] - (v[n] >> LEAK) + (i_raw << 10)
            if vnext >= vth:
                fired.append(n)
                cnt[n] += 1
                v[n] = 0
                refra[n] = REFRA
            else:
                v[n] = max(VMIN, min(VMAX, vnext))
        raster.append(fired)
    return cnt, raster


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--act", required=True)
    ap.add_argument("--weights", default="mem/weights_snn.hex")
    ap.add_argument("--out", required=True)
    ap.add_argument("--steps", type=int, default=64)
    ap.add_argument("--nneu", type=int, default=16)
    ap.add_argument("--nin", type=int, default=64)
    args = ap.parse_args()

    act = [int(x, 16) for x in Path(args.act).read_text().split()]
    w = [int(x, 16) for x in Path(args.weights).read_text().split()]
    assert len(act) == args.nin and len(w) == args.nneu * args.nin

    cnt, raster = run(act, w, args.nneu, args.nin, args.steps)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(f"{c:02X}" for c in cnt) + "\n")
    total = sum(cnt)
    print(f"golden SNN -> {args.out}  spike counts={cnt} total={total}")


if __name__ == "__main__":
    main()
