#!/usr/bin/env python3
"""
Visual side-by-side comparison: render a Console screenshot next to a Notion
reference at matching body-line-height, with horizontal guidelines drawn
across both at every detected text band. The output is a single PNG that
makes it obvious when a heading→paragraph or paragraph→paragraph gap
doesn't match the reference.

Usage:
    compare-typography.py <screenshot.png> <reference.{png,jpg,webp}> [--out diff.png]
                          [--screenshot-region X0 Y0 X1 Y1]
                          [--reference-region X0 Y0 X1 Y1]

The script:
  1. Crops each image to its content column (auto-detected, or use --*-region).
  2. Detects horizontal text bands in each by projecting ink onto y.
  3. Estimates body line-height = 25th-percentile of consecutive band centers.
  4. Scales the screenshot so its body-LH matches the reference's body-LH.
  5. Writes diff.png: reference on the left, scaled screenshot on the right.
     A red horizontal rule is drawn across the FULL width at every band edge,
     so misaligned gaps are visible at a glance.

Open the output in Preview / VS Code; matching means red lines line up
horizontally between the two halves.
"""
from __future__ import annotations
import sys
import argparse
from pathlib import Path

try:
    from PIL import Image, ImageDraw
    import numpy as np
except ImportError:
    print("error: needs Pillow and numpy. install with:", file=sys.stderr)
    print("    /usr/bin/python3 -m pip install --user pillow numpy", file=sys.stderr)
    sys.exit(2)


def detect_content_column(arr: np.ndarray) -> tuple[int, int]:
    h, w = arr.shape
    ink = (arr < 200).sum(axis=0)
    kernel = np.ones(11) / 11
    smooth = np.convolve(ink, kernel, mode="same")
    threshold = max(smooth.max() * 0.05, 2)
    x_in = np.where(smooth > threshold)[0]
    return (int(x_in[0]), int(x_in[-1] + 1)) if len(x_in) else (0, w)


def find_text_bands(arr: np.ndarray) -> list[tuple[int, int]]:
    """Project ink onto y. Return list of (top, bottom) per text band."""
    ink = (arr < 200).sum(axis=1)
    has_ink = ink > max(ink.max() * 0.02, 1)
    bands: list[tuple[int, int]] = []
    in_band = False
    band_start = 0
    for y, present in enumerate(has_ink):
        if present and not in_band:
            in_band, band_start = True, y
        elif not present and in_band:
            in_band = False
            bands.append((band_start, y))
    if in_band:
        bands.append((band_start, len(has_ink)))
    return bands


def body_line_height(bands: list[tuple[int, int]]) -> float:
    centers = [(t + b) / 2 for t, b in bands]
    deltas = sorted(centers[i + 1] - centers[i] for i in range(len(centers) - 1))
    if not deltas:
        return float("nan")
    return deltas[len(deltas) // 4]   # 25th-percentile is within-paragraph leading


def crop_and_analyse(path: Path, region: tuple[int, int, int, int] | None):
    img = Image.open(path).convert("RGB")
    if region:
        img = img.crop(region)
    gray = np.asarray(img.convert("L"))
    x0, x1 = detect_content_column(gray)
    pad = 24
    x0 = max(0, x0 - pad)
    x1 = min(gray.shape[1], x1 + pad)
    cropped = img.crop((x0, 0, x1, gray.shape[0]))
    cropped_gray = np.asarray(cropped.convert("L"))
    bands = find_text_bands(cropped_gray)
    body_lh = body_line_height(bands)
    return cropped, bands, body_lh


def draw_band_rules(img: Image.Image, bands: list[tuple[int, int]], color="#cc2222", width=1) -> Image.Image:
    out = img.copy()
    draw = ImageDraw.Draw(out)
    for top, bot in bands:
        draw.line([(0, top), (out.width, top)], fill=color, width=width)
        draw.line([(0, bot), (out.width, bot)], fill="#2266cc", width=width)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("screenshot")
    ap.add_argument("reference")
    ap.add_argument("--out", default="typography-diff.png")
    ap.add_argument("--screenshot-region", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"))
    ap.add_argument("--reference-region", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"))
    args = ap.parse_args()

    s_img, s_bands, s_lh = crop_and_analyse(Path(args.screenshot), tuple(args.screenshot_region) if args.screenshot_region else None)
    r_img, r_bands, r_lh = crop_and_analyse(Path(args.reference), tuple(args.reference_region) if args.reference_region else None)

    print(f"reference body-line-px: {r_lh:.2f}  ({len(r_bands)} bands)")
    print(f"screenshot body-line-px: {s_lh:.2f}  ({len(s_bands)} bands)")
    if s_lh < 1 or r_lh < 1:
        print("error: couldn't detect body line-height. try passing --*-region.", file=sys.stderr)
        sys.exit(1)

    # Scale screenshot so its body-LH matches the reference.
    scale = r_lh / s_lh
    new_w = max(1, int(round(s_img.width * scale)))
    new_h = max(1, int(round(s_img.height * scale)))
    s_scaled = s_img.resize((new_w, new_h), Image.LANCZOS)
    # Re-detect bands on the scaled image so guidelines line up.
    s_scaled_bands = find_text_bands(np.asarray(s_scaled.convert("L")))

    s_drawn = draw_band_rules(s_scaled, s_scaled_bands)
    r_drawn = draw_band_rules(r_img, r_bands)

    gap = 16
    out_w = r_drawn.width + gap + s_drawn.width
    out_h = max(r_drawn.height, s_drawn.height)
    canvas = Image.new("RGB", (out_w, out_h), "white")
    canvas.paste(r_drawn, (0, 0))
    canvas.paste(s_drawn, (r_drawn.width + gap, 0))

    # Label each half along the top.
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([(0, 0), (r_drawn.width, 24)], fill="#fff8c8")
    draw.text((6, 4), f"reference: {Path(args.reference).name}  body-LH={r_lh:.1f}px", fill="#444")
    draw.rectangle([(r_drawn.width + gap, 0), (out_w, 24)], fill="#e8f0ff")
    draw.text((r_drawn.width + gap + 6, 4), f"screenshot scaled ×{scale:.2f}  body-LH={r_lh:.1f}px", fill="#444")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.out)
    print(f"wrote {args.out}  ({out_w}×{out_h})")


if __name__ == "__main__":
    main()
