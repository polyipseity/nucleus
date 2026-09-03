#!/usr/bin/env python3
"""Strip metadata from embedded images inside OOXML ZIP archives.

Extracts the OOXML archive, runs exiftool -all= on media files in
*/media/ directories, then reassembles the ZIP preserving per-entry
compression method and file order.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print(
            f"Usage: {sys.argv[0]} <source> <destination> <exiftool-path>",
            file=sys.stderr,
        )
        return 1

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    exiftool_path = sys.argv[3]

    if not zipfile.is_zipfile(source):
        print(f"Error: '{source}' is not a valid ZIP file.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        with zipfile.ZipFile(source, "r") as zin:
            infos = zin.infolist()
            for info in infos:
                zin.extract(info, tmp)

        # Collect media extensions (case-insensitive match).
        media_exts = ("jpg", "jpeg", "png", "gif", "tiff", "bmp")
        media_files: list[Path] = []
        for ext in media_exts:
            media_files.extend(tmp.rglob(f"**/media/*.{ext}"))
            media_files.extend(tmp.rglob(f"**/media/*.{ext.upper()}"))
        # Deduplicate while preserving order.
        seen: set[str] = set()
        unique_media: list[Path] = []
        for mf in media_files:
            key = str(mf)
            if key not in seen:
                seen.add(key)
                unique_media.append(mf)

        files_processed = 0
        for mf in unique_media:
            result = subprocess.run(
                [exiftool_path, "-all=", "-overwrite_original", str(mf)],
                check=False,
            )
            if result.returncode != 0:
                print(
                    f"Warning: exiftool failed on '{mf}'.",
                    file=sys.stderr,
                )
            else:
                files_processed += 1

        try:
            with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as zout:
                for info in infos:
                    if info.is_dir():
                        continue
                    extracted = tmp / info.filename
                    data = extracted.read_bytes()
                    out_info = zipfile.ZipInfo(
                        filename=info.filename,
                        date_time=info.date_time,
                    )
                    out_info.compress_type = info.compress_type
                    zout.writestr(out_info, data, compress_type=info.compress_type)
        except Exception:
            if destination.exists():
                destination.unlink()
            print(f"Error: failed to write output ZIP.", file=sys.stderr)
            return 1

    print(
        f"stripped embedded media metadata: {files_processed} files processed",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
