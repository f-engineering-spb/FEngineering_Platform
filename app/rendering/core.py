"""F-Engineering Platform v3.2 — fast rendering core.

Single routing point for all previewable formats. Platform standard:
PREVIEW_DPI = 150 for every raster coming from CAD/PDF pages.
"""

from __future__ import annotations

import os

PREVIEW_DPI = 150
FIRST_PAGE_IMMEDIATE = True
IMAGE_MAX_EDGE = 1920

CAD_KINDS = {"dwg", "dxf"}
PDF_KINDS = {"pdf"}
EXCEL_KINDS = {"xlsx", "xlsm", "xls"}
WORD_KINDS = {"docx", "doc"}
IMAGE_KINDS = {"jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp"}
TEXT_KINDS = {"txt", "log", "md"}

#: Everything else opens in the default desktop application, no rendering.
NATIVE_APP_EXTS = frozenset({
    "mpp", "mpx", "mov", "mp4", "avi", "mkv", "wmv",
    "zip", "rar", "7z", "rvt", "rfa", "ifc", "skp",
    "exe", "msi", "ppt", "pptx", "csv",
})

_EXTENSION_TO_KIND = {}
for _ext in CAD_KINDS:
    _EXTENSION_TO_KIND[_ext] = "cad"
for _ext in PDF_KINDS:
    _EXTENSION_TO_KIND[_ext] = "pdf"
for _ext in EXCEL_KINDS:
    _EXTENSION_TO_KIND[_ext] = "excel"
for _ext in WORD_KINDS:
    _EXTENSION_TO_KIND[_ext] = "word"
for _ext in IMAGE_KINDS:
    _EXTENSION_TO_KIND[_ext] = "image"
for _ext in TEXT_KINDS:
    _EXTENSION_TO_KIND[_ext] = "text"


def extension_of(path) -> str:
    return os.path.splitext(str(path))[1].lower().lstrip(".")


def classify(path) -> str:
    """Return preview kind: cad/pdf/excel/word/image/text/native_app/unknown."""
    ext = extension_of(path)
    if ext in _EXTENSION_TO_KIND:
        return _EXTENSION_TO_KIND[ext]
    if ext in NATIVE_APP_EXTS:
        return "native_app"
    return "unknown"


def get_file_preview(path, dpi: int = PREVIEW_DPI) -> dict:
    """Route any file to its preview descriptor.

    Never raises for unknown types: falls back to ``native_app`` so the UI
    can render a placeholder card with an "open in default app" button.
    """
    kind = classify(path)
    name = os.path.basename(str(path))
    try:
        size = os.path.getsize(str(path))
    except OSError:
        size = -1
    if kind in ("cad", "pdf"):
        try:
            from .cad_proxy import pdf_first_page_info
        except ImportError:  # pragma: no cover - standalone layout
            from cad_proxy import pdf_first_page_info  # type: ignore
        info = pdf_first_page_info(str(path), dpi=dpi) if kind == "pdf" else {"pages": None}
        return {"kind": kind, "name": name, "size": size, "dpi": dpi,
                "immediate_first_page": FIRST_PAGE_IMMEDIATE, **info}
    if kind == "excel":
        try:
            from .excel_fast import open_workbook
        except ImportError:  # pragma: no cover
            from excel_fast import open_workbook  # type: ignore
        return {"kind": kind, "name": name, "size": size,
                "sheets": open_workbook(str(path)).sheet_names()}
    if kind == "word":
        try:
            from .word_fast import describe as word_describe
        except ImportError:  # pragma: no cover
            from word_fast import describe as word_describe  # type: ignore
        return {"kind": kind, "name": name, "size": size, **word_describe(str(path))}
    if kind == "image":
        try:
            from .image_safe import describe as image_describe
        except ImportError:  # pragma: no cover
            from image_safe import describe as image_describe  # type: ignore
        return {"kind": kind, "name": name, "size": size, **image_describe(str(path))}
    if kind == "text":
        return {"kind": kind, "name": name, "size": size, "dpi": None}
    try:
        from .native_cards import describe as native_describe
    except ImportError:  # pragma: no cover
        from native_cards import describe as native_describe  # type: ignore
    return native_describe(str(path))
