#!/usr/bin/env python3
"""gen_test_image.py — 生成 Canny/SNN 仿真激励图像 (hex, 每行一个像素字节).

用法:
  python scripts/gen_test_image.py --size 64 --pattern edge --out sim/stimulus/test_image_64x64.hex
  python scripts/gen_test_image.py --size 64 --pattern edgecase --out sim/stimulus/test_edge_case.hex

图案:
  flat   — 全 128 (零梯度, 验证无虚假边缘)
  edge   — 垂直/水平/斜阶跃 + 亮斑 (经典 Canny 验证)
  noise  — 带 LFSR 种子的伪随机 (可复现)
  edgecase — 极端值: 全黑/全白区、单像素线、棋格、饱和条带
"""
import argparse
import random
from pathlib import Path


def clamp(v):
    return max(0, min(255, v))


def gen(pattern, w, h):
    img = [[0] * w for _ in range(h)]
    if pattern == "flat":
        for y in range(h):
            for x in range(w):
                img[y][x] = 128
    elif pattern == "edge":
        for y in range(h):
            for x in range(w):
                v = 60
                if x >= w // 2:
                    v = 180            # 垂直阶跃
                if y >= h // 2:
                    v = clamp(v + 60)  # 水平阶跃
                img[y][x] = v
        # 斜阶跃
        for y in range(h):
            for x in range(w):
                if x - y > w // 4:
                    img[y][x] = clamp(img[y][x] + 50)
        # 亮斑 (需超过 5x5 窗)
        cy, cx, r = h // 5, w // 5, max(3, w // 10)
        for y in range(h):
            for x in range(w):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    img[y][x] = 230
    elif pattern == "noise":
        rnd = random.Random(20260815)   # 固定种子, 可复现
        for y in range(h):
            for x in range(w):
                img[y][x] = rnd.randint(0, 255)
    elif pattern == "edgecase":
        for y in range(h):
            for x in range(w):
                img[y][x] = 0
        # 白色矩形 (饱和)
        for y in range(h // 8, h // 4):
            for x in range(w // 8, w // 4):
                img[y][x] = 255
        # 棋格 8x8
        for y in range(h // 2, h - h // 8):
            for x in range(w // 2, w - w // 8):
                img[y][x] = 255 if ((x // 4) + (y // 4)) % 2 else 0
        # 单像素宽对角线
        for i in range(w // 8):
            img[h - 1 - i][i] = 200
        # 渐变条带 (幅值饱和路径)
        for y in range(h - h // 6, h):
            for x in range(w):
                img[y][x] = clamp((x * 255) // max(1, w - 1))
    else:
        raise SystemExit(f"unknown pattern: {pattern}")
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--pattern", default="edge",
                    choices=["flat", "edge", "noise", "edgecase"])
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    img = gen(args.pattern, args.size, args.size)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as f:
        for row in img:
            f.write("\n".join(f"{p:02X}" for p in row))
            f.write("\n")
    print(f"wrote {args.size}x{args.size} '{args.pattern}' -> {out} "
          f"({args.size*args.size} pixels)")


if __name__ == "__main__":
    main()
