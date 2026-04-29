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
    """Project ink onto y. Return list of (top, bottom) per text band.

    Uses a strict ink threshold (`<150`) to skip anti-aliased halos and the
    pale gray of window chrome. Then applies a 1D morphological closing —
    a tunable run-length close — so that the small white gap between the
    cap-row and descender-row of a single text line is bridged (treating
    a single line as one band) but the inter-line gap stays open."""
    ink = (arr < 150).sum(axis=1)
    median = float(np.median(ink))
    threshold = median + max((ink.max() - median) * 0.10, 4)
    has_ink = ink > threshold

    # Estimate a target close-distance: small enough to merge within-line
    # gaps but smaller than typical inter-line gap. ~6px of closure works
    # for both 16-18px Notion body type and 16pt Inter at 2× retina.
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
    # Drop bands shorter than half a typical x-height (anti-alias artifacts).
    return [b for b in bands if (b[1] - b[0]) >= 5]


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


"""Hardcoded reference body line-heights. All four were measured by running
`measure-typography.py` with explicit --xrange (content column) and --yrange
(a multi-line body paragraph), then taking the bottom-to-bottom delta of
within-paragraph consecutive lines. If a diff comes out with the screenshot
text obviously larger or smaller than the reference text, re-measure and
fix the corresponding entry here."""
REFERENCE_BODY_LH_PX = {
    "notion_prompt_example.png":          43,
    "notion_example_page_formatting.jpg": 31,
    "notion_full_width_page.png":         48,
    "notion_ai_for_docs.webp":            30,
}

# Console renders body at 16pt with `bodyLineSpacing = 5`, so SwiftUI emits
# baseline-to-baseline of (16pt natural-leading ≈ 19pt) + 5pt = 24pt. At 2x
# retina that's 48px. Matches the screenshots we capture via screencapture -l.
SCREENSHOT_BODY_LH_PX = 48


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("screenshot")
    ap.add_argument("reference")
    ap.add_argument("--out", default="typography-diff.png")
    ap.add_argument("--screenshot-region", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"))
    ap.add_argument("--reference-region", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"))
    ap.add_argument("--ref-body-lh", type=float,
                    help="override reference body-LH in px (otherwise looked up by filename)")
    ap.add_argument("--screenshot-body-lh", type=float, default=SCREENSHOT_BODY_LH_PX)
    args = ap.parse_args()

    ref_lh = args.ref_body_lh
    if ref_lh is None:
        ref_lh = REFERENCE_BODY_LH_PX.get(Path(args.reference).name)
        if ref_lh is None:
            print("error: unknown reference image; pass --ref-body-lh", file=sys.stderr)
            sys.exit(1)
    scr_lh = args.screenshot_body_lh

    s_img, s_bands, _ = crop_and_analyse(Path(args.screenshot), tuple(args.screenshot_region) if args.screenshot_region else None)
    r_img, r_bands, _ = crop_and_analyse(Path(args.reference), tuple(args.reference_region) if args.reference_region else None)

    # Scale screenshot so its body line-height matches the reference's.
    scale = ref_lh / scr_lh
    new_w = max(1, int(round(s_img.width * scale)))
    new_h = max(1, int(round(s_img.height * scale)))
    s_scaled = s_img.resize((new_w, new_h), Image.LANCZOS)
    s_bands_scaled = [(int(round(t * scale)), int(round(b * scale))) for t, b in s_bands]

    header_h = 28
    gap = 16
    out_w = r_img.width + gap + s_scaled.width
    out_h = max(r_img.height, s_scaled.height) + header_h
    canvas = Image.new("RGB", (out_w, out_h), "white")
    canvas.paste(r_img, (0, header_h))
    canvas.paste(s_scaled, (r_img.width + gap, header_h))

    draw = ImageDraw.Draw(canvas)
    draw.rectangle([(0, 0), (r_img.width, header_h)], fill="#fff8c8")
    draw.text((6, 6), f"reference: {Path(args.reference).name}  body-LH={ref_lh}px", fill="#444")
    draw.rectangle([(r_img.width + gap, 0), (out_w, header_h)], fill="#e8f0ff")
    draw.text(
        (r_img.width + gap + 6, 6),
        f"screenshot scaled ×{scale:.3f} (so body-LH matches at {ref_lh}px)",
        fill="#444",
    )

    # Red horizontal rule across the FULL diff width at every band edge in
    # each side. Misaligned gaps show up as a red line that lands in
    # different vertical positions on the two halves. Top edges in red,
    # bottoms in a paler red so the within-band height is also visible.
    def draw_rules(bands: list[tuple[int, int]], x_start: int, x_end: int) -> None:
        for top, bot in bands:
            y_top = top + header_h
            y_bot = bot + header_h
            draw.line([(x_start, y_top), (x_end, y_top)], fill=(255, 0, 0, 90), width=1)
            draw.line([(x_start, y_bot), (x_end, y_bot)], fill=(255, 180, 180, 90), width=1)

    draw_rules(r_bands, 0, r_img.width)
    draw_rules(s_bands_scaled, r_img.width + gap, out_w)

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.out)
    print(f"wrote {args.out}  ({out_w}×{out_h})  scale=×{scale:.3f}")


if __name__ == "__main__":
    main()
