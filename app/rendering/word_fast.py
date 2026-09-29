"""Fast DOCX preview: pure python-docx to clean HTML.

Target: <1.5 s for a ~35 page document. No Word COM, no PDF round-trip.
Legacy .doc files report a COM fallback instead of raising.
"""

from __future__ import annotations

import html
import os


def describe(path: str) -> dict:
    ext = os.path.splitext(str(path))[1].lower()
    if ext == ".doc":
        return {"engine": "com_fallback", "reason": "legacy .doc needs Word COM"}
    return {"engine": "word_fast"}


def _para_html(para) -> str:
    text = html.escape(para.text or "")
    if not text.strip():
        return "<p>&nbsp;</p>"
    style = (para.style.name or "").lower()
    if style.startswith("heading 1"):
        return "<h1>%s</h1>" % text
    if style.startswith("heading 2"):
        return "<h2>%s</h2>" % text
    if style.startswith("heading 3"):
        return "<h3>%s</h3>" % text
    if "list" in style or "bullet" in style:
        return "<li>%s</li>" % text
    if para.runs and all(getattr(r, "bold", False) for r in para.runs if r.text):
        return "<p><strong>%s</strong></p>" % text
    return "<p>%s</p>" % text


def _table_html(table) -> str:
    out = ["<table>"]
    for row in table.rows:
        out.append("<tr>")
        for cell in row.cells:
            content = "".join(_para_html(p) for p in cell.paragraphs)
            out.append("<td>%s</td>" % content)
        out.append("</tr>")
    out.append("</table>")
    return "".join(out)


def docx_to_html(path: str, max_chars: int = 2_000_000) -> str:
    """Convert .docx body to a single self-contained HTML fragment."""
    import docx  # python-docx

    document = docx.Document(str(path))
    parts = [
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:900px;margin:0 auto;"
        "padding:24px;line-height:1.5}table{border-collapse:collapse;width:100%;margin:12px 0}"
        "td,th{border:1px solid #999;padding:6px 8px}h1,h2,h3{color:#1a3a5c}</style>"
        "</head><body>"
    ]
    # Walk body elements in document order so tables keep their position.
    body = document.element.body
    for child in body.iterchildren():
        tag = child.tag.split("}")[-1]
        if tag == "p":
            from docx.text.paragraph import Paragraph
            parts.append(_para_html(Paragraph(child, document)))
        elif tag == "tbl":
            from docx.table import Table
            parts.append(_table_html(Table(child, document)))
        if sum(len(p) for p in parts) > max_chars:
            parts.append("<p><em>…truncated…</em></p>")
            break
    parts.append("</body></html>")
    return "".join(parts)
