#!/usr/bin/env python3
"""golden_model.py — Canny 流水线黄金参考模型.

必须与 RTL (rtl/img_proc/*) 逐位一致, 算法顺序冻结为:
  gaussian_5x5 -> scharr_3x3 -> gradient_mag_dir -> median_3x3
  -> nms -> double_threshold -> hysteresis

定点规则 (与 doc/architecture.md §.3 冻结):
  - 边界处理: 所有窗口 replicate(复制最近边缘像素)
  - gaussian: 可分离 [1,4,6,4,1]^2, 水平累加全精度, 垂直累加后
              out = clamp((acc + 128) >> 8, 0, 255)   -- 四舍五入
  - scharr:   Gx=[-3,0,3;-10,0,10;-3,0,3] (x 向右正)
              Gy=[-3,-10,-3;0,0,0;3,10,3]  (y 向下正)
              12-bit 有符号饱和 [-2048, 2047]
  - mag:      |Gx|+|Gy| 饱和到 12-bit 无符号 [0, 4095]
  - dir:      2-bit, 边界用整数比较 |Gy|*10000 vs |Gx|*4142 / *24142
              (即 22.5deg / 67.5deg, == 归下侧)
  - median:   3x3 窗 9 值中值 (作用在 mag 上)
  - nms:      mag >= 两侧邻居 才保留 (平局保留), 否则 0
  - thresh:   mag >= th_high -> strong(2); >= th_low -> weak(1); 否则 0
  - hysteresis: strong 种子, weak 与 edge 8 连通则晋升, 迭代至收敛

用法:
  python scripts/golden_model.py --in sim/stimulus/test_image_64x64.hex \
      --size 64 --out sim/reference/golden_output.hex [--dump-dir sim/reference]
"""
import argparse
from pathlib import Path

TH_HIGH = 600
TH_LOW = 200


def read_hex(path):
    data = [int(t, 16) for t in Path(path).read_text().split()]
    return data


def replicate_img(img, w, t, b, cp=2):
    """上下各补 t/b 行零, 左右各补 cp 列零 (默认 2 列供 5x5; 3x3 用 cp=1)"""
    h = len(img)
    out = []
    for _ in range(t):
        out.append([0] * (cp + w + cp))
    for y in range(h):
        out.append([0] * cp + img[y] + [0] * cp)
    for _ in range(b):
        out.append([0] * (cp + w + cp))
    return out


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def gaussian(img, w):
    h = len(img)
    e = replicate_img(img, w, 2, 2)
    out = [[0] * w for _ in range(h)]
    K = (1, 4, 6, 4, 1)
    for y in range(h):
        for x in range(w):
            acc = 0
            for dy in range(5):
                hacc = 0
                row = e[y + dy]
                for dx in range(5):
                    hacc += K[dx] * row[x + dx]
                acc += K[dy] * hacc
            out[y][x] = clamp((acc + 128) >> 8, 0, 255)
    return out


def scharr_mag_dir(g, w):
    h = len(g)
    e = replicate_img(g, w, 1, 1, cp=1)
    gx = [[0] * w for _ in range(h)]
    gy = [[0] * w for _ in range(h)]
    mag = [[0] * w for _ in range(h)]
    dr = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            a, b, c = e[y][x], e[y][x + 1], e[y][x + 2]
            d, f = e[y + 1][x], e[y + 1][x + 2]
            gg, i_, j = e[y + 2][x], e[y + 2][x + 1], e[y + 2][x + 2]
            sx = -3 * a + 3 * c - 10 * d + 10 * f - 3 * gg + 3 * j
            sy = -3 * a - 10 * b - 3 * c + 3 * gg + 10 * i_ + 3 * j
            sx = clamp(sx, -2048, 2047)
            sy = clamp(sy, -2048, 2047)
            gx[y][x] = sx
            gy[y][x] = sy
            mag[y][x] = clamp(abs(sx) + abs(sy), 0, 4095)
            ax, ay = abs(sx), abs(sy)
            if ay * 10000 <= ax * 4142:
                dr[y][x] = 0
            elif ay * 10000 >= ax * 24142:
                dr[y][x] = 2
            else:
                dr[y][x] = 1 if (sx >= 0) == (sy >= 0) else 3
    return gx, gy, mag, dr


def median3(m, w):
    h = len(m)
    e = replicate_img(m, w, 1, 1, cp=1)
    out = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            win = [e[y + dy][x + dx] for dy in range(3) for dx in range(3)]
            win.sort()
            out[y][x] = win[4]
    return out


def nms(mag, dr, w):
    h = len(mag)
    out = [[0] * w for _ in range(h)]

    def at(y, x):
        yy = clamp(y, 0, h - 1)
        xx = clamp(x, 0, w - 1)
        return mag[yy][xx]

    for y in range(h):
        for x in range(w):
            d = dr[y][x]
            if d == 0:
                n1, n2 = at(y, x - 1), at(y, x + 1)
            elif d == 2:
                n1, n2 = at(y - 1, x), at(y + 1, x)
            elif d == 1:
                n1, n2 = at(y - 1, x - 1), at(y + 1, x + 1)
            else:
                n1, n2 = at(y - 1, x + 1), at(y + 1, x - 1)
            m = mag[y][x]
            out[y][x] = m if (m >= n1 and m >= n2) else 0
    return out


def double_threshold(mag, w, th_hi=TH_HIGH, th_lo=TH_LOW):
    h = len(mag)
    out = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            m = mag[y][x]
            out[y][x] = 2 if m >= th_hi else (1 if m >= th_lo else 0)
    return out


def hysteresis(cls, w):
    h = len(cls)
    edge = [[1 if cls[y][x] == 2 else 0 for x in range(w)] for y in range(h)]
    changed = True
    while changed:
        changed = False
        for y in range(h):
            for x in range(w):
                if cls[y][x] == 1 and not edge[y][x]:
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            yy, xx = y + dy, x + dx
                            if 0 <= yy < h and 0 <= xx < w and edge[yy][xx]:
                                edge[y][x] = 1
                                changed = True
                                break
    return edge


def to_lines(img, fmt="{:02X}"):
    lines = []
    for row in img:
        lines.extend(fmt.format(v & 0xFF if fmt == "{:02X}" else v) for v in row)
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--out", required=True)
    ap.add_argument("--dump-dir", default=None,
                    help="输出中间级 hex (gauss/gx/gy/mag/dir/median/nms)")
    ap.add_argument("--th-high", type=int, default=TH_HIGH)
    ap.add_argument("--th-low", type=int, default=TH_LOW)
    args = ap.parse_args()

    n = args.size
    data = read_hex(args.inp)
    assert len(data) == n * n, f"expect {n*n} pixels, got {len(data)}"
    img = [data[y * n:(y + 1) * n] for y in range(n)]

    g = gaussian(img, n)
    gx, gy, mag, dr = scharr_mag_dir(g, n)
    med = median3(mag, n)
    nm = nms(med, dr, n)
    cls = double_threshold(nm, n, args.th_high, args.th_low)
    edge = hysteresis(cls, n)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join("{:02X}".format(v) for row in edge for v in row) + "\n")
    nedge = sum(sum(r) for r in edge)
    print(f"golden edge map -> {out}  ({nedge} edge pixels / {n*n})")

    if args.dump_dir:
        dd = Path(args.dump_dir)
        dd.mkdir(parents=True, exist_ok=True)
        (dd / "gauss.hex").write_text("\n".join("{:02X}".format(v) for r in g for v in r) + "\n")
        (dd / "gx.hex").write_text("\n".join("{:04X}".format(v & 0xFFF) for r in gx for v in r) + "\n")
        (dd / "gy.hex").write_text("\n".join("{:04X}".format(v & 0xFFF) for r in gy for v in r) + "\n")
        (dd / "mag.hex").write_text("\n".join("{:03X}".format(v) for r in mag for v in r) + "\n")
        (dd / "dir.hex").write_text("\n".join("{:01X}".format(v) for r in dr for v in r) + "\n")
        (dd / "median.hex").write_text("\n".join("{:03X}".format(v) for r in med for v in r) + "\n")
        (dd / "nms.hex").write_text("\n".join("{:03X}".format(v) for r in nm for v in r) + "\n")
        print(f"intermediate dumps -> {dd}/")


if __name__ == "__main__":
    main()
