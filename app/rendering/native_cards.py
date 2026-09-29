"""Native cards: placeholder descriptors for files we never render.

MPP, video, archives, RVT and friends get an info card (icon, name, size)
plus an "open in default app" action served by POST /api/open-file.
TXT/LOG additionally get a fast monospace HTML preview with clickable links.
"""

from __future__ import annotations

import html
import os
import re

_LINK_RE = re.compile(r"(https?://[^\s<\"']+)")


def describe(path: str) -> dict:
    name = os.path.basename(str(path))
    try:
        size = os.path.getsize(str(path))
    except OSError:
        size = -1
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    return {"kind": "native_app", "name": name, "size": size, "ext": ext,
            "icon": "file", "action": "open-file",
            "engine": "native_cards"}


def _decode_text(raw: bytes) -> tuple:
    for encoding in ("utf-8-sig", "utf-8", "windows-1251"):
        try:
            return raw.decode(encoding), encoding
        except (UnicodeDecodeError, ValueError):
            continue
    return raw.decode("windows-1251", errors="replace"), "windows-1251?"


def text_to_html(path: str, max_chars: int = 500_000) -> str:
    """Monospace HTML with http/https links made clickable."""
    with open(str(path), "rb") as fh:
        raw = fh.read(max_chars + 1)
    truncated = len(raw) > max_chars
    text, encoding = _decode_text(raw[:max_chars])
    safe = html.escape(text)
    linked = _LINK_RE.sub(r'<a href="\1" target="_blank" rel="noopener">\1</a>', safe)
    tail = "<p><em>…truncated…</em></p>" if truncated else ""
    return (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<style>body{font-family:Consolas,monospace;white-space:pre-wrap;"
        "max-width:1000px;margin:0 auto;padding:24px}</style>"
        "</head><body><!--encoding:%s-->%s%s</body></html>" % (encoding, linked, tail)
    )
