#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_NAME="AppIcon"
ICON_SOURCE="${REPO_ROOT}/${ICON_NAME}.icon"
OUTPUT_ICNS="${REPO_ROOT}/${ICON_NAME}.icns"

if [ ! -d "${ICON_SOURCE}" ] || [ ! -f "${ICON_SOURCE}/icon.json" ]; then
  echo "Icon source not found: ${ICON_SOURCE}"
  exit 1
fi

if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
  echo "Required tools not available: sips/iconutil"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
PNG_DIR="${TMP_DIR}/png"
ICONSET_DIR="${TMP_DIR}/${ICON_NAME}.iconset"
mkdir -p "${PNG_DIR}" "${ICONSET_DIR}"

if [ ! -d "${PNG_DIR}" ]; then
  echo "Failed to create temporary PNG directory"
  exit 1
fi

for source_svg in "${ICON_SOURCE}/Assets/"*.svg; do
  svg_name="$(basename "${source_svg}")"
  target_png="${PNG_DIR}/${svg_name%.svg}.png"
  sips -s format png --resampleWidth 1024 --resampleHeight 1024 "${source_svg}" --out "${target_png}" >/dev/null
done

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ICON_SOURCE="${ICON_SOURCE}" \
TMP_DIR="${TMP_DIR}" \
python3 - <<'PY'
import json
import os
from pathlib import Path
from PIL import Image

icon_root = Path(os.environ["ICON_SOURCE"])
tmp_dir = Path(os.environ["TMP_DIR"])
png_dir = tmp_dir / "png"
iconset_dir = tmp_dir / "AppIcon.iconset"

icon_json = json.loads((icon_root / "icon.json").read_text())
groups = icon_json.get("groups", [])
fill = icon_json.get("fill", {}).get("linear-gradient", [])
fill = fill if len(fill) == 2 else None
orientation = icon_json.get("fill", {}).get("orientation", {})
start = orientation.get("start", {"x": 0, "y": 0})
end = orientation.get("stop", {"x": 1, "y": 0})

def parse_color(value):
    if value is None:
        return (0, 0, 0)
    if isinstance(value, str):
        _, _, color_data = value.partition(":")
        parts = color_data.split(",")
        try:
            return tuple(
                max(0, min(255, int(float(part) * 255)))
                for part in parts[:3]
            )
        except ValueError:
            return (0, 0, 0)
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        return tuple(max(0, min(255, int(float(v) * 255))) for v in value[:3])
    return (0, 0, 0)

start_rgb = parse_color(fill[0] if fill else None)
end_rgb = parse_color(fill[1] if fill else None)

size = 1024
sx = float(start.get("x", 0))
sy = float(start.get("y", 0))
ex = float(end.get("x", 1))
ey = float(end.get("y", 0))
dx = ex - sx
dy = ey - sy
denom = (dx * dx + dy * dy) or 1.0

base = Image.new("RGBA", (size, size))
base_pixels = base.load()
for y in range(size):
    py = y / (size - 1) if size > 1 else 0
    for x in range(size):
        px = x / (size - 1) if size > 1 else 0
        t = ((px - sx) * dx + (py - sy) * dy) / denom
        t = max(0.0, min(1.0, t))
        r = int(start_rgb[0] + (end_rgb[0] - start_rgb[0]) * t)
        g = int(start_rgb[1] + (end_rgb[1] - start_rgb[1]) * t)
        b = int(start_rgb[2] + (end_rgb[2] - start_rgb[2]) * t)
        base_pixels[x, y] = (r, g, b, 255)

for layer in [layer_item for group in groups for layer_item in group.get("layers", [])]:
    image_name = layer.get("image-name")
    if not image_name:
        continue
    opacity = float(layer.get("opacity", 1.0))
    layer_png = png_dir / f"{image_name}.png"
    if not layer_png.exists():
        continue
    layer_image = Image.open(layer_png).convert("RGBA").resize((size, size))
    if opacity < 1.0:
        alpha = layer_image.getchannel("A").point(lambda value: int(value * opacity))
        layer_image.putalpha(alpha)
    base.alpha_composite(layer_image)

composed_path = tmp_dir / "AppIcon.png"
base.save(composed_path, "PNG")

required_sizes = [16, 32, 64, 128, 256, 512]
for pixel_size in required_sizes:
    icon_path = iconset_dir / f"icon_{pixel_size}x{pixel_size}.png"
    layer_image = base.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
    layer_image.save(icon_path, "PNG")

    doubled = pixel_size * 2
    if doubled <= 1024:
        retina_path = iconset_dir / f"icon_{pixel_size}x{pixel_size}@2x.png"
        retina_image = base.resize((doubled, doubled), Image.Resampling.LANCZOS)
        retina_image.save(retina_path, "PNG")

if not composed_path.exists():
    raise RuntimeError("Failed to create composed icon")
PY

iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICNS}"
