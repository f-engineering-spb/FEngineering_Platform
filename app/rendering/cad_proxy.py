"""CAD/PDF raster proxy: crisp 150 DPI PNG via PyMuPDF, first page first.

No AutoCAD is touched here: DWG sheets arrive as rendered PDF pages from
the silent COM pipeline (app/scripts/render_dwg_smart.ps1) and are rastered
below. Page 1 is always available immediately for the card thumbnail.
"""

from __future__ import annotations

try:
    from .core import PREVIEW_DPI
except ImportError:  # pragma: no cover - standalone layout
    PREVIEW_DPI = 150


def page_count(path: str) -> int:
    import fitz

    with fitz.open(str(path)) as doc:
        return doc.page_count


def render_page_png(path: str, page: int = 1, dpi: int = PREVIEW_DPI) -> bytes:
    """Render one PDF page to PNG bytes at the platform DPI."""
    import fitz

    with fitz.open(str(path)) as doc:
        if page < 1 or page > doc.page_count:
            raise ValueError("page %d out of range (1..%d)" % (page, doc.page_count))
        pix = doc[page - 1].get_pixmap(dpi=dpi)
        return pix.tobytes("png")


def first_page_png(path: str, dpi: int = PREVIEW_DPI) -> bytes:
    """Immediate page-1 raster for drawing cards."""
    return render_page_png(str(path), page=1, dpi=dpi)


def pdf_first_page_info(path: str, dpi: int = PREVIEW_DPI) -> dict:
    import fitz

    with fitz.open(str(path)) as doc:
        count = doc.page_count
        rect = doc[0].rect if count else None
    return {"pages": count,
            "first_page_size_pt": [round(rect.width, 1), round(rect.height, 1)] if rect else None,
            "engine": "cad_proxy"}
