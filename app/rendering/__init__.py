"""F-Engineering Platform rendering core package (v3.2, 150 DPI standard)."""

from .core import (
    PREVIEW_DPI,
    FIRST_PAGE_IMMEDIATE,
    IMAGE_MAX_EDGE,
    NATIVE_APP_EXTS,
    classify,
    extension_of,
    get_file_preview,
)

__all__ = [
    "PREVIEW_DPI",
    "FIRST_PAGE_IMMEDIATE",
    "IMAGE_MAX_EDGE",
    "NATIVE_APP_EXTS",
    "classify",
    "extension_of",
    "get_file_preview",
]
