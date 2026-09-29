# CORE ARCH RULES — F-Engineering Platform v3.2

Single source of layout truth: this repo (`main` branch). The old
`f-engineering-launcher` history stays archived and is never a donor.

## 1. Rendering standard (all formats)

- CAD/PDF raster: **150 DPI PNG via PyMuPDF** (`app/rendering/cad_proxy.py`,
  `PREVIEW_DPI = 150`). 300 DPI is never the default; the `dpi` API parameter
  still accepts 72–600 for explicit quality requests.
- Page 1 is always served immediately for card thumbnails.
- Excel: parse the workbook **once**, cache **every** sheet in LRU
  (`app/rendering/excel_fast.py`). `.xls` via xlrd, `.xlsx/.xlsm` via openpyxl.
- Word: `.docx` preview is **pure python-docx HTML** (no COM, no PDF
  round-trip). Legacy `.doc` falls back to Word COM explicitly.
- Images: Pillow with guarded EXIF transpose (never rotate an already
  portrait frame), downscale edges over 1920 px to screen raster.
- TXT/LOG: encoding detect UTF-8 → Windows-1251, monospace, http(s) links
  become clickable `<a>`.
- Everything else (MPP, video, archives, RVT…): **no rendering attempts**.
  `native_app` card (icon, name, size) + `POST /api/open-file`.

## 2. Silent DWG pipeline

- `app/scripts/render_dwg_smart.ps1` only writes PDF/PNG into cache and exits.
  It MUST NOT open the result in any external viewer (no `Start-Process`,
  no `Invoke-Item`, no `ShellExecute` on outputs; verified by grep).
- Before plotting it freezes regen (`LAYOUTREGENCTL=2`, `REGENMODE=0`,
  `BACKGROUNDPLOT=0`, `EXPERT=5`) and cuts online traffic
  (`ONLINESTATUS=0`, `WSCOMMNTR=0`, both in try/catch so unknown names can
  never abort a render) — this keeps Proxifier out of the loop.
- The backend drives it via `DWG_SMART_RENDER_SCRIPT`
  (`app/backend/server.py`); the constant points inside `app/scripts/`.

## 3. Backend / frontend contract

- Backend: stdlib `ThreadingHTTPServer`, entry
  `python app/backend/server.py --host 127.0.0.1 --port 8780`.
  Only `http://127.0.0.1:8780/` is a supported address.
- One silent entry point: `Запуск_Лаунчера.vbs` (no console) → pythonw server
  → opens the UI URL. `Запуск_Лаунчера.cmd` only discovers that VBS.
- DWG previews are PDF pairs; pairing prefers exact matches over doubtful ones.
- Runtime data (`runtime/`, caches, manifests, logs) is derived and disposable;
  originals and folder structure are never mutated by previews.

## 4. Change discipline

- Small verifiable changes; Cyrillic is first-class (UTF-8 everywhere,
  `scripts/check_encoding` equivalent before/after text edits).
- Never commit caches, previews, logs, object files, secrets, temp outputs.
- New modules go to `app/rendering/` with dual-safe imports
  (`try: from .x except ImportError: from x`) and zero CAD/COM at import time.
