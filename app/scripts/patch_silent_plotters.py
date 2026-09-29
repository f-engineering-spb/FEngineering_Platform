"""
Utility to patch Autodesk AutoCAD PC3 printer configuration files to disable automatic PDF opening.
By default, Autodesk's PDF PC3 drivers (DWG To PDF.pc3, AutoCAD PDF (...).pc3) have:
    name="View_New_File
    value=TRUE
When AutoCAD plots via PlotToFile(), pdfplot16.hdi reads this setting and uses Win32 ShellExecute
to launch the default PDF viewer (Edge / Acrobat), causing unwanted popup windows.
This utility patches View_New_File to FALSE in all found PC3 files and creates FEng_Silent_DWG_To_PDF.pc3.
"""

import glob
import os
import struct
import sys
import zlib


def patch_pc3_file(path: str) -> bool:
    if not os.path.exists(path):
        return False
    try:
        with open(path, "rb") as f:
            data = f.read()
    except Exception as e:
        print(f"[PC3 PATCH] Error reading {path}: {e}")
        return False

    if not data.startswith(b"PIAFILEVERSION_2.0,PC3VER1,compress"):
        return False

    prefix = data[:52]
    try:
        decomp_sz, comp_sz = struct.unpack("<II", data[52:60])
        compressed_bytes = data[60:60 + comp_sz]
        decompressed = zlib.decompress(compressed_bytes)
    except Exception as e:
        print(f"[PC3 PATCH] Error decompressing {path}: {e}")
        return False

    target_pattern = b'name="View_New_File\n  value=TRUE\n'
    replacement = b'name="View_New_File\n  value=FALSE\n'

    if target_pattern in decompressed:
        patched_decomp = decompressed.replace(target_pattern, replacement)
        new_compressed = zlib.compress(patched_decomp, 9)
        new_header = prefix + struct.pack("<II", len(patched_decomp), len(new_compressed))
        new_data = new_header + new_compressed
        try:
            with open(path, "wb") as f:
                f.write(new_data)
            print(f"[PC3 PATCH] Patched to silent: {os.path.basename(path)}")
            return True
        except Exception as e:
            print(f"[PC3 PATCH] Error writing {path}: {e}")
            return False
    return False


def ensure_silent_plotters(extra_dirs=None):
    search_dirs = []
    if extra_dirs:
        for d in extra_dirs:
            if d and os.path.isdir(d):
                search_dirs.append(d)

    appdata = os.environ.get("APPDATA", "")
    if appdata:
        autodesk_dir = os.path.join(appdata, "Autodesk")
        if os.path.isdir(autodesk_dir):
            search_dirs.append(autodesk_dir)

    patched_count = 0
    pc3_files = []
    for base in search_dirs:
        pc3_files.extend(glob.glob(os.path.join(base, "**", "*.pc3"), recursive=True))

    plotter_dirs = set()
    for pc3 in set(pc3_files):
        plotter_dirs.add(os.path.dirname(pc3))
        if patch_pc3_file(pc3):
            patched_count += 1

    # Ensure dedicated FEng_Silent_DWG_To_PDF.pc3 in all plotter dirs
    for pdir in plotter_dirs:
        silent_target = os.path.join(pdir, "FEng_Silent_DWG_To_PDF.pc3")
        dwg_to_pdf = os.path.join(pdir, "DWG To PDF.pc3")
        source = None
        if os.path.exists(dwg_to_pdf):
            source = dwg_to_pdf
        elif os.path.exists(silent_target):
            source = silent_target
        else:
            candidates = glob.glob(os.path.join(pdir, "*PDF*.pc3"))
            if candidates:
                source = candidates[0]

        if source and source != silent_target:
            try:
                import shutil
                shutil.copy2(source, silent_target)
                patch_pc3_file(silent_target)
                print(f"[PC3 PATCH] Created/Updated {silent_target}")
            except Exception as e:
                print(f"[PC3 PATCH] Could not copy {source} to {silent_target}: {e}")
        elif os.path.exists(silent_target):
            patch_pc3_file(silent_target)

    print(f"[PC3 PATCH] Done. {patched_count} files patched across {len(plotter_dirs)} plotter directory(ies).")


if __name__ == "__main__":
    extra = sys.argv[1:] if len(sys.argv) > 1 else None
    ensure_silent_plotters(extra)
