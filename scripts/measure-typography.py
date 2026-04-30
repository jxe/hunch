#!/usr/bin/env python3
"""
Measure typographic spacing in a screenshot or reference image.

Strategy: project ink onto the y-axis (sum of darkness per row), threshold
to find text bands, and report band centers / heights / inter-band gaps.
Then express every gap as a multiple of the *body* line-height — that is
the only resolution-independent number, and it cancels out the fact that
the reference images are 1500-1900px wide while our screenshots are 2880×.

Usage:
    measure-typography.py <image-path> [--xrange x0 x1] [--yrange y0 y1]

If --xrange is omitted, the script auto-detects the content column by
finding the widest contiguous stripe of low-variance whitespace on either
side of the densest x-band.

Output is a YAML-ish report:
    file: <path>
    image_size: WxH
    column: x0..x1
    body_line_pt: <px>
    bands:
      - { y_top, y_bot, height, gap_above_px, gap_above_lh }
      ...
    summary:
      median_within_paragraph_lh: ...
      heading_to_body_lh: ...
      ...

Run after each tuning pass on both your Hunch screenshot AND the
matching reference; compare the band-gap ratios. If your screenshot's
heading→body ratio is 1.4× and the reference is 1.8×, you need to
increase that gap.
"""
from __future__ import annotations
import sys
import argparse
from pathlib import Path

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("error: this script needs Pillow and numpy. install with:", file=sys.stderr)
    print("    /usr/bin/python3 -m pip install --user pillow numpy", file=sys.stderr)
    sys.exit(2)


def detect_content_column(arr: np.ndarray) -> tuple[int, int]:
    """Return (x0, x1) of the content column. Heuristic: drop the leftmost
    and rightmost 5% of width that contain any chrome, then trim from each
    side until we hit a column with at least 2% ink."""
    h, w = arr.shape
    ink = (arr < 200).sum(axis=0)
    # Smooth a bit so that single-character columns don't bias us.
    kernel = np.ones(11) / 11
    smooth = np.convolve(ink, kernel, mode="same")
    threshold = max(smooth.max() * 0.05, 2)
    x_in = np.where(smooth > threshold)[0]
    if len(x_in) == 0:
        return 0, w
    return int(x_in[0]), int(x_in[-1] + 1)


def find_text_bands(arr: np.ndarray, x0: int, x1: int) -> list[tuple[int, int]]:
    """Project ink darkness over [x0, x1] onto the y-axis and return a list
    of (y_top, y_bot) bounds, one per text band (line of text).

    Uses a strict ink threshold (`<150`) plus a 1D morphological-closing pass
    that bridges the small white gap between a line's cap-row and its
    descender-row, so a single line of text counts as one band rather than
    several artifact sub-bands. Without this, a paragraph with descenders
    yields N×2-ish bands and the 25th-percentile delta falls into the
    cap-to-descender gap (a few px) instead of the actual baseline-to-baseline
    line-height. Mirrors `compare-typography.py:find_text_bands`."""
    column = arr[:, x0:x1]
    ink = (column < 150).sum(axis=1)
    median = float(np.median(ink))
    threshold = median + max((ink.max() - median) * 0.10, 4)
    has_ink = ink > threshold

    close_distance = 6
    closed = has_ink.copy()
    run_zero = 0
    last_one_idx = -1
    for i in range(len(closed)):
        if closed[i]:
            if 0 < run_zero <= close_distance and last_one_idx >= 0:
                closed[last_one_idx + 1 : i] = True
            run_zero = 0
            last_one_idx = i
        else:
            run_zero += 1

    bands: list[tuple[int, int]] = []
    in_band = False
    band_start = 0
    for y, present in enumerate(closed):
        if present and not in_band:
            in_band, band_start = True, y
        elif not present and in_band:
            in_band = False
            bands.append((band_start, y))
    if in_band:
        bands.append((band_start, len(closed)))
    return [b for b in bands if (b[1] - b[0]) >= 5]


def measure(path: Path, xrange: tuple[int, int] | None, yrange: tuple[int, int] | None) -> dict:
    img = Image.open(path).convert("L")
    arr = np.asarray(img)
    h, w = arr.shape

    if yrange:
        y0, y1 = yrange
        arr = arr[y0:y1, :]
    else:
        y0 = 0

    if xrange:
        x0, x1 = xrange
    else:
        x0, x1 = detect_content_column(arr)

    bands = find_text_bands(arr, x0, x1)
    if not bands:
        return {"file": str(path), "image_size": f"{w}x{h}", "bands": []}

    # Estimate body line-height: median of small gaps between consecutive
    # bands (gaps within a paragraph, not between paragraphs / headings).
    centers = [(t + b) / 2 for t, b in bands]
    deltas = [centers[i + 1] - centers[i] for i in range(len(centers) - 1)]
    if deltas:
        sorted_d = sorted(deltas)
        body_lh = sorted_d[len(sorted_d) // 4]   # 25th-percentile delta ≈ within-paragraph
    else:
        body_lh = float("nan")

    rows = []
    for i, (t, b) in enumerate(bands):
        gap_px = (t - bands[i - 1][1]) if i > 0 else 0
        rows.append({
            "y_top": t + y0,
            "y_bot": b + y0,
            "height": b - t,
            "gap_above_px": gap_px,
            "gap_above_lh": round(gap_px / body_lh, 2) if body_lh and i > 0 else 0,
        })

    return {
        "file": str(path),
        "image_size": f"{w}x{h}",
        "column": f"{x0}..{x1}",
        "body_line_px": round(body_lh, 2),
        "bands": rows,
    }


def render(report: dict) -> str:
    out = [f"file: {report['file']}", f"image_size: {report['image_size']}"]
    if "column" in report:
        out.append(f"column: {report['column']}")
        out.append(f"body_line_px: {report['body_line_px']}")
    out.append("bands:")
    for i, row in enumerate(report["bands"]):
        out.append(
            f"  [{i:>3}] y={row['y_top']:>5}..{row['y_bot']:<5} "
            f"h={row['height']:>3} gap_above={row['gap_above_px']:>4}px "
            f"({row['gap_above_lh']}× body-line)"
        )
    return "\n".join(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--xrange", nargs=2, type=int, metavar=("X0", "X1"))
    ap.add_argument("--yrange", nargs=2, type=int, metavar=("Y0", "Y1"))
    args = ap.parse_args()

    xrange = tuple(args.xrange) if args.xrange else None
    yrange = tuple(args.yrange) if args.yrange else None
    report = measure(Path(args.image), xrange, yrange)
    print(render(report))


if __name__ == "__main__":
    main()
