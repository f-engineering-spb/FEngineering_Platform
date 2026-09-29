"""Safe image preview: Pillow with guarded EXIF orientation.

- EXIF transpose is applied only when the orientation tag actually demands
  it, so an already-portrait frame (h > w) is never knocked on its side.
- Photos with an edge over IMAGE_MAX_EDGE are downscaled to a screen raster.
"""

from __future__ import annotations

import io
import os

try:
    from .core import IMAGE_MAX_EDGE
except ImportError:  # pragma: no cover - standalone layout
    IMAGE_MAX_EDGE = 1920

_EXIF_ORIENTATION_TAG = 0x0112
_ORIENTATIONS_NEEDING_WORK = frozenset({2, 3, 4, 5, 6, 7, 8})


def _needs_transpose(image) -> bool:
    try:
        exif = image.getexif()
    except Exception:
        return False
    if not exif:
        return False
    orientation = exif.get(_EXIF_ORIENTATION_TAG, 1)
    return orientation in _ORIENTATIONS_NEEDING_WORK


def open_safe(path: str):
    """Open an image with correct orientation and bounded size."""
    from PIL import Image, ImageOps

    image = Image.open(str(path))
    try:
        if _needs_transpose(image):
            image = ImageOps.exif_transpose(image)
        w, h = image.size
        edge = max(w, h)
        if edge > IMAGE_MAX_EDGE:
            scale = IMAGE_MAX_EDGE / float(edge)
            image = image.resize((max(1, int(w * scale)), max(1, int(h * scale))),
                                 Image.LANCZOS)
        if image.mode in ("RGBA", "LA", "PA"):
            background = Image.new("RGB", image.size, (255, 255, 255))
            background.paste(image, mask=image.split()[-1])
            image = background
        elif image.mode != "RGB":
            image = image.convert("RGB")
    except Exception:
        pass
    return image


def to_screen_png(path: str) -> bytes:
    """Screen-ready PNG bytes for the viewer (native 100% scale)."""
    buf = io.BytesIO()
    open_safe(path).save(buf, format="PNG")
    return buf.getvalue()


def describe(path: str) -> dict:
    from PIL import Image

    with Image.open(str(path)) as probe:
        w, h = probe.size
    return {"engine": "image_safe", "width": w, "height": h,
            "mode": "native",
            "downscaled": max(w, h) > IMAGE_MAX_EDGE,
            "size": os.path.getsize(str(path))}
