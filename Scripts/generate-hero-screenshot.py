#!/usr/bin/env python3
"""
Generate the JustNow website hero screenshot.

Two modes:
  1. Overlay mode (default):  Takes a full JustNow overlay screenshot and
     adds a selection rectangle + crosshair cursor on top.
  2. Compose mode (--compose): Takes just a content screenshot and draws the
     full JustNow overlay chrome around it, then adds the selection.

Usage:
    # Mode 1 — full overlay base
    python3 Scripts/generate-hero-screenshot.py base.png output.jpg

    # Mode 2 — content only
    python3 Scripts/generate-hero-screenshot.py content.png output.jpg --compose

Styling is matched to UI/TextGrabSelectionOverlay.swift and
UI/CaptureOverlayView.swift.
"""

import argparse
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ── Fonts ──────────────────────────────────────────────────────────────────

def _load_font(size: int, mono: bool = False) -> ImageFont.FreeTypeFont:
    """Load a system font, falling back gracefully."""
    candidates = (
        ["/System/Library/Fonts/SFNSMono.ttf"] if mono else
        ["/System/Library/Fonts/SFNS.ttf",
         "/System/Library/Fonts/Helvetica.ttc"]
    )
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except (OSError, IOError):
            continue
    return ImageFont.load_default()


# ── Selection box styling (from TextGrabSelectionOverlay.swift) ────────────

FILL_OPACITY = 0.14
BORDER_OPACITY = 0.58
BORDER_WIDTH_PT = 1.8
CORNER_RADIUS_PT = 9
SHADOW_OPACITY = 0.50
SHADOW_RADIUS_PT = 3
SHADOW_OFFSET = (0, 1)

# Crosshair cursor (from ScreenshotCursor)
CURSOR_ARM_RADIUS = 14
CURSOR_CENTER_GAP = 1.5
CURSOR_RING_RADIUS = 6.4
CURSOR_OUTER_WIDTH = 3.0
CURSOR_OUTER_ALPHA = 0.39
CURSOR_INNER_WIDTH = 1.7
CURSOR_INNER_ALPHA = 0.96

# ── Chrome styling (from CaptureOverlayView.swift) ────────────────────────

CHROME_BUTTON_SIZE_PT = 40
CHROME_BUTTON_BG = (0, 0, 0, int(255 * 0.72))
CHROME_BUTTON_BORDER = (255, 255, 255, int(255 * 0.10))
CHROME_BUTTON_ICON = (255, 255, 255, int(255 * 0.86))
CHROME_TOP_PAD_PT = 24
CHROME_SIDE_PAD_PT = 28

PILL_BG = (0, 0, 0, int(255 * 0.85))
PILL_BORDER = (255, 255, 255, int(255 * 0.08))
PILL_TEXT_COLOUR = (255, 255, 255, int(255 * 0.70))

TIMELINE_BG = (0, 0, 0, int(255 * 0.85))
TIMELINE_BORDER = (255, 255, 255, int(255 * 0.08))
TIMELINE_CORNER_PT = 20
TIMELINE_TRACK_H_PT = 10
TIMELINE_TRACK_BG = (48, 48, 54, 255)
TIMELINE_SCRUBBER_SIZE_PT = 24

TOAST_BG = (0, 0, 0, int(255 * 0.62))
TOAST_BORDER = (255, 255, 255, int(255 * 0.08))
TOAST_TITLE_COLOUR = (255, 255, 255, 255)
TOAST_SUBTITLE_COLOUR = (255, 255, 255, int(255 * 0.72))
TOAST_SUCCESS_TINT = (184, 235, 199, 255)

LABEL_COLOUR = (255, 255, 255, int(255 * 0.60))
MARKER_COLOUR = (255, 255, 255, int(255 * 0.45))

INFO_BUTTON_BG = (0, 0, 0, int(255 * 0.50))
INFO_BUTTON_BORDER = (255, 255, 255, int(255 * 0.10))


# ── Helpers ────────────────────────────────────────────────────────────────

def px(pt: float, scale: float = 2.0) -> int:
    return round(pt * scale)


def draw_circle_button(
    draw: ImageDraw.ImageDraw,
    cx: int, cy: int,
    size_px: int,
    bg: tuple, border: tuple, icon_colour: tuple,
    icon_char: str,
    font: ImageFont.FreeTypeFont,
):
    """Draw a circular button with a centred character."""
    r = size_px // 2
    bbox = (cx - r, cy - r, cx + r, cy + r)
    draw.ellipse(bbox, fill=bg, outline=border, width=2)
    # Centre the icon character
    tb = draw.textbbox((0, 0), icon_char, font=font)
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    draw.text(
        (cx - tw // 2, cy - th // 2 - tb[1]),
        icon_char, fill=icon_colour, font=font,
    )


def draw_capsule(
    draw: ImageDraw.ImageDraw,
    bbox: tuple[int, int, int, int],
    fill: tuple, outline: tuple,
):
    """Draw a capsule (fully rounded rectangle)."""
    x1, y1, x2, y2 = bbox
    radius = (y2 - y1) // 2
    draw.rounded_rectangle(bbox, radius=radius, fill=fill, outline=outline, width=2)


# ── Selection overlay ─────────────────────────────────────────────────────

def draw_rounded_rect_shadow(
    size: tuple[int, int],
    bbox: tuple[int, int, int, int],
    radius: int, shadow_radius: int,
    shadow_offset: tuple[int, int], shadow_alpha: float,
) -> Image.Image:
    sx, sy = shadow_offset
    shadow_bbox = (bbox[0] + sx, bbox[1] + sy, bbox[2] + sx, bbox[3] + sy)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        shadow_bbox, radius=radius,
        fill=(0, 0, 0, int(255 * shadow_alpha)),
    )
    return layer.filter(ImageFilter.GaussianBlur(radius=shadow_radius))


def draw_selection_box(
    base: Image.Image,
    rect: tuple[int, int, int, int],
    scale: float = 2.0,
) -> Image.Image:
    result = base.copy().convert("RGBA")
    x1, y1, x2, y2 = rect
    border_w = px(BORDER_WIDTH_PT, scale)
    radius = px(CORNER_RADIUS_PT, scale)
    shadow_r = px(SHADOW_RADIUS_PT, scale)
    shadow_off = (px(SHADOW_OFFSET[0], scale), px(SHADOW_OFFSET[1], scale))

    shadow = draw_rounded_rect_shadow(
        result.size, rect, radius, shadow_r, shadow_off, SHADOW_OPACITY)
    result = Image.alpha_composite(result, shadow)

    fill_layer = Image.new("RGBA", result.size, (0, 0, 0, 0))
    ImageDraw.Draw(fill_layer).rounded_rectangle(
        rect, radius=radius, fill=(0, 0, 0, int(255 * FILL_OPACITY)))
    result = Image.alpha_composite(result, fill_layer)

    border_layer = Image.new("RGBA", result.size, (0, 0, 0, 0))
    ImageDraw.Draw(border_layer).rounded_rectangle(
        rect, radius=radius,
        outline=(255, 255, 255, int(255 * BORDER_OPACITY)),
        width=border_w)
    result = Image.alpha_composite(result, border_layer)
    return result


def draw_crosshair(
    base: Image.Image,
    pos: tuple[int, int],
    scale: float = 2.0,
) -> Image.Image:
    result = base.copy().convert("RGBA")
    cx, cy = pos
    arm = px(CURSOR_ARM_RADIUS, scale)
    gap = px(CURSOR_CENTER_GAP, scale)
    ring_r = px(CURSOR_RING_RADIUS, scale)

    layer = Image.new("RGBA", result.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    white = (255, 255, 255, int(255 * CURSOR_OUTER_ALPHA))
    black = (0, 0, 0, int(255 * CURSOR_INNER_ALPHA))
    ow = max(1, px(CURSOR_OUTER_WIDTH, scale))
    iw = max(1, px(CURSOR_INNER_WIDTH, scale))

    for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        s = (cx + dx * gap, cy + dy * gap)
        e = (cx + dx * arm, cy + dy * arm)
        draw.line([s, e], fill=white, width=ow)
        draw.line([s, e], fill=black, width=iw)

    ring_bb = (cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r)
    draw.ellipse(ring_bb, outline=white, width=max(1, px(2.9, scale)))
    draw.ellipse(ring_bb, outline=black, width=max(1, px(1.6, scale)))
    return Image.alpha_composite(result, layer)


# ── Compose mode — draw full JustNow overlay chrome ───────────────────────

def compose_overlay(
    content: Image.Image,
    scale: float = 2.0,
    toast_title: str = "Copied to clipboard",
    toast_subtitle: str = "",
    time_label: str = "Yesterday 15:54",
) -> Image.Image:
    """
    Draw the full JustNow overlay chrome around a content screenshot.

    Returns the composited image ready for selection overlay.
    """
    w, h = content.size

    # ── Fonts at various sizes ──
    font_icon = _load_font(px(16, scale))
    font_icon_sm = _load_font(px(14, scale))
    font_pill = _load_font(px(11, scale))
    font_label = _load_font(px(10, scale))
    font_marker = _load_font(px(10, scale))
    font_toast_title = _load_font(px(13, scale))
    font_toast_sub = _load_font(px(11, scale))
    font_info = _load_font(px(14, scale))

    # ── Base: content with slight dimming ──
    # The overlay dims the captured frame very slightly at the edges
    result = content.copy().convert("RGBA")

    # Apply rounded corners to the content frame (16pt radius)
    frame_radius = px(16, scale)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, w, h), radius=frame_radius, fill=255)
    bg = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    result = Image.composite(result, bg, mask)

    chrome = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(chrome)

    btn_size = px(CHROME_BUTTON_SIZE_PT, scale)
    top_pad = px(CHROME_TOP_PAD_PT, scale)
    side_pad = px(CHROME_SIDE_PAD_PT, scale)
    btn_cy = top_pad + btn_size // 2

    # ── Close button (X) — top-left ──
    draw_circle_button(
        draw, side_pad + btn_size // 2, btn_cy, btn_size,
        CHROME_BUTTON_BG, CHROME_BUTTON_BORDER, CHROME_BUTTON_ICON,
        "\u00D7", font_icon,  # × multiplication sign
    )

    # ── Instruction pill — top-centre ──
    pill_text = "\u21C4  drag to grab text    \u2318 /"
    pill_tb = draw.textbbox((0, 0), pill_text, font=font_pill)
    pill_tw = pill_tb[2] - pill_tb[0]
    pill_h = px(36, scale)
    pill_w = pill_tw + px(28, scale)
    pill_x1 = (w - pill_w) // 2
    pill_y1 = top_pad + (btn_size - pill_h) // 2
    draw_capsule(draw,
        (pill_x1, pill_y1, pill_x1 + pill_w, pill_y1 + pill_h),
        PILL_BG, PILL_BORDER)
    draw.text(
        (pill_x1 + px(14, scale),
         pill_y1 + (pill_h - (pill_tb[3] - pill_tb[1])) // 2 - pill_tb[1]),
        pill_text, fill=PILL_TEXT_COLOUR, font=font_pill)

    # ── Search button — top-right ──
    draw_circle_button(
        draw, w - side_pad - btn_size // 2, btn_cy, btn_size,
        CHROME_BUTTON_BG, CHROME_BUTTON_BORDER, CHROME_BUTTON_ICON,
        "\u2315", font_icon,  # ⌕ telephone recorder / approximate search icon
    )

    # ── Navigation arrows — mid-left/right ──
    arrow_cy = h // 2 - px(40, scale)  # slightly above centre (above timeline)
    draw_circle_button(
        draw, side_pad + btn_size // 2, arrow_cy, btn_size,
        CHROME_BUTTON_BG, CHROME_BUTTON_BORDER, CHROME_BUTTON_ICON,
        "\u2039", font_icon,  # ‹
    )
    draw_circle_button(
        draw, w - side_pad - btn_size // 2, arrow_cy, btn_size,
        CHROME_BUTTON_BG, CHROME_BUTTON_BORDER, CHROME_BUTTON_ICON,
        "\u203A", font_icon,  # ›
    )

    # ── Info button — lower-right of content ──
    info_size = px(32, scale)
    info_cx = w - px(60, scale)
    info_cy = h - px(200, scale)
    draw_circle_button(
        draw, info_cx, info_cy, info_size,
        INFO_BUTTON_BG, INFO_BUTTON_BORDER,
        (255, 255, 255, int(255 * 0.7)),
        "i", font_info,
    )

    # ── Timeline area — bottom ──
    tl_h = px(100, scale)
    tl_pad_x = px(40, scale)
    tl_pad_bottom = px(24, scale)
    tl_y1 = h - tl_pad_bottom - tl_h
    tl_corner = px(TIMELINE_CORNER_PT, scale)

    # Timeline background
    draw.rounded_rectangle(
        (tl_pad_x, tl_y1, w - tl_pad_x, h - tl_pad_bottom),
        radius=tl_corner, fill=TIMELINE_BG, outline=TIMELINE_BORDER, width=2)

    # Time range labels
    inner_pad = px(16, scale)
    label_y = tl_y1 + px(10, scale)
    draw.text((tl_pad_x + inner_pad, label_y),
              time_label, fill=LABEL_COLOUR, font=font_label)
    now_tb = draw.textbbox((0, 0), "Now", font=font_label)
    draw.text((w - tl_pad_x - inner_pad - (now_tb[2] - now_tb[0]), label_y),
              "Now", fill=LABEL_COLOUR, font=font_label)

    # Track
    track_h = px(TIMELINE_TRACK_H_PT, scale)
    track_y = tl_y1 + px(30, scale)
    track_x1 = tl_pad_x + inner_pad
    track_x2 = w - tl_pad_x - inner_pad
    draw.rounded_rectangle(
        (track_x1, track_y, track_x2, track_y + track_h),
        radius=track_h // 2, fill=TIMELINE_TRACK_BG)

    # Coloured zones on track (older → newer gradient)
    zone_border = track_x1 + int((track_x2 - track_x1) * 0.75)
    older_colour = (77, 71, 79, int(255 * 0.88))
    newer_colour = (140, 133, 143, int(255 * 0.88))
    # Green progress bar (indicating captured range)
    progress_end = track_x1 + int((track_x2 - track_x1) * 0.92)
    draw.rounded_rectangle(
        (track_x1, track_y, progress_end, track_y + track_h),
        radius=track_h // 2, fill=(80, 140, 90, int(255 * 0.6)))

    # Scrubber handle
    scrubber_r = px(TIMELINE_SCRUBBER_SIZE_PT, scale) // 2
    scrubber_x = progress_end
    scrubber_cy = track_y + track_h // 2
    draw.ellipse(
        (scrubber_x - scrubber_r, scrubber_cy - scrubber_r,
         scrubber_x + scrubber_r, scrubber_cy + scrubber_r),
        fill=(255, 255, 255, 255))

    # Time markers below track
    marker_y = track_y + track_h + px(8, scale)
    markers = ["08:00", "10:00", "2h", "1h", "30min", "10min", "5min"]
    marker_positions = [0.05, 0.18, 0.38, 0.52, 0.65, 0.78, 0.90]
    for label, frac in zip(markers, marker_positions):
        mx = track_x1 + int((track_x2 - track_x1) * frac)
        mtb = draw.textbbox((0, 0), label, font=font_marker)
        mw = mtb[2] - mtb[0]
        draw.text((mx - mw // 2, marker_y), label,
                  fill=MARKER_COLOUR, font=font_marker)

    # ── Toast — bottom-centre ──
    toast_pad_x = px(16, scale)
    toast_pad_y = px(11, scale)
    # Build toast text
    icon_char = "\u2713"  # ✓ checkmark
    full_title = f"  {icon_char}  {toast_title}"
    title_tb = draw.textbbox((0, 0), full_title, font=font_toast_title)
    title_tw = title_tb[2] - title_tb[0]
    title_th = title_tb[3] - title_tb[1]

    has_sub = bool(toast_subtitle)
    sub_th = 0
    sub_tw = 0
    if has_sub:
        sub_tb = draw.textbbox((0, 0), toast_subtitle, font=font_toast_sub)
        sub_tw = sub_tb[2] - sub_tb[0]
        sub_th = sub_tb[3] - sub_tb[1]

    toast_content_w = max(title_tw, sub_tw)
    toast_w = toast_content_w + toast_pad_x * 2
    toast_content_h = title_th + (px(4, scale) + sub_th if has_sub else 0)
    toast_h = toast_content_h + toast_pad_y * 2
    toast_x1 = (w - toast_w) // 2
    toast_y1 = h - px(12, scale) - toast_h

    draw_capsule(draw,
        (toast_x1, toast_y1, toast_x1 + toast_w, toast_y1 + toast_h),
        TOAST_BG, TOAST_BORDER)

    # Toast icon (green checkmark circle)
    check_r = px(9, scale)
    check_cx = toast_x1 + toast_pad_x + check_r
    check_cy = toast_y1 + toast_pad_y + title_th // 2
    draw.ellipse(
        (check_cx - check_r, check_cy - check_r,
         check_cx + check_r, check_cy + check_r),
        fill=TOAST_SUCCESS_TINT)
    # Checkmark inside
    check_font = _load_font(px(10, scale))
    ctb = draw.textbbox((0, 0), "\u2713", font=check_font)
    draw.text(
        (check_cx - (ctb[2] - ctb[0]) // 2,
         check_cy - (ctb[3] - ctb[1]) // 2 - ctb[1]),
        "\u2713", fill=(0, 0, 0, 230), font=check_font)

    # Toast title text
    text_x = check_cx + check_r + px(8, scale)
    text_y = toast_y1 + toast_pad_y - title_tb[1]
    draw.text((text_x, text_y), toast_title,
              fill=TOAST_TITLE_COLOUR, font=font_toast_title)

    # Toast subtitle
    if has_sub:
        draw.text(
            (text_x, text_y + title_th + px(2, scale)),
            toast_subtitle, fill=TOAST_SUBTITLE_COLOUR, font=font_toast_sub)

    result = Image.alpha_composite(result, chrome)
    return result


# ── Default selection rect ────────────────────────────────────────────────

def auto_selection_rect(w: int, h: int) -> tuple[int, int, int, int]:
    """Default selection covering the typical headline area."""
    return (round(w * 0.19), round(h * 0.35),
            round(w * 0.50), round(h * 0.59))


# ── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Generate the JustNow hero screenshot.")
    parser.add_argument(
        "base", nargs="?", default="site/assets/hero-base.png",
        help="Base or content screenshot path")
    parser.add_argument(
        "output", nargs="?", default="site/assets/justnow-overlay-hero.jpg",
        help="Output path")
    parser.add_argument(
        "--compose", action="store_true",
        help="Compose mode: treat base as content-only and draw overlay chrome")
    parser.add_argument(
        "--rect", type=str, default=None,
        help="Selection rect as x1,y1,x2,y2 (auto if omitted)")
    parser.add_argument(
        "--cursor", type=str, default=None,
        help="Crosshair position as x,y (auto if omitted, 'none' to disable)")
    parser.add_argument(
        "--toast-title", type=str, default="Copied to clipboard",
        help="Toast title text (compose mode)")
    parser.add_argument(
        "--toast-subtitle", type=str, default="",
        help="Toast subtitle text (compose mode, auto-generated if empty)")
    parser.add_argument(
        "--time-label", type=str, default="Yesterday 15:54",
        help="Left time label on timeline (compose mode)")
    parser.add_argument(
        "--no-selection", action="store_true",
        help="Skip drawing the selection rectangle")
    parser.add_argument(
        "--scale", type=float, default=2.0,
        help="Retina scale factor (default: 2.0)")
    parser.add_argument(
        "--quality", type=int, default=88,
        help="JPEG quality (default: 88)")

    args = parser.parse_args()

    base_path = Path(args.base)
    if not base_path.exists():
        print(f"Base image not found: {base_path}", file=sys.stderr)
        sys.exit(1)

    base = Image.open(base_path).convert("RGBA")
    w, h = base.size
    print(f"Input: {w}\u00d7{h}")

    # Compose mode: draw full overlay chrome
    if args.compose:
        toast_sub = args.toast_subtitle
        if not toast_sub:
            # Auto-generate subtitle from a plausible OCR preview
            toast_sub = "Illuminate your journey into tech. Learn coding and digital making from \u2026"
        result = compose_overlay(
            base, scale=args.scale,
            toast_title=args.toast_title,
            toast_subtitle=toast_sub,
            time_label=args.time_label,
        )
    else:
        result = base

    # Selection rectangle
    if not args.no_selection:
        if args.rect:
            parts = [int(v) for v in args.rect.split(",")]
            rect = tuple(parts)
        else:
            rect = auto_selection_rect(w, h)
        print(f"Selection: {rect}")
        result = draw_selection_box(result, rect, scale=args.scale)

        # Crosshair cursor
        if args.cursor != "none":
            if args.cursor:
                cpos = tuple(int(v) for v in args.cursor.split(","))
            else:
                cpos = (
                    rect[0] + round((rect[2] - rect[0]) * 0.75),
                    rect[1] + round((rect[3] - rect[1]) * 0.75),
                )
            print(f"Cursor: {cpos}")
            result = draw_crosshair(result, cpos, scale=args.scale)

    # Save
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.suffix.lower() in (".jpg", ".jpeg"):
        result = result.convert("RGB")
        result.save(out_path, "JPEG", quality=args.quality)
    else:
        result.save(out_path, "PNG")
    print(f"Saved: {out_path} ({out_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
