#!/usr/bin/env bash
# nucleus-gs-pdf-opt: Optimize PDF files with Ghostscript (backup/restore).
set -euo pipefail

gs_pdf_opt() {
  local preset="default"
  local files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        echo "Usage: $(basename "$0") [--preset <name>] <file>..."
        echo ""
        echo "Optimize PDF files using Ghostscript. Creates .bak backup before processing."
        echo ""
        echo "Presets (default: default):"
        echo "  default   - high quality"
        echo "  ebook     - medium quality (good for e-readers)"
        echo "  prepress  - high quality (preserves color, suitable for printing)"
        echo "  printer   - medium quality for printing"
        echo "  screen    - low quality (smallest file)"
        echo ""
        echo "If a .bak file already exists for any input, the command refuses and exits."
        echo "On failure, the original file is restored from backup."
        return 0
        ;;
      --preset)
        preset="$2"
        shift 2
        ;;
      --preset=*)
        preset="${1#*=}"
        shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Usage: gs_pdf_opt [--preset <name>] <file>..." >&2
    return 1
  fi

  case "$preset" in
    default|ebook|prepress|printer|screen) ;;
    *)
      echo "Unknown preset: $preset (valid: default, ebook, prepress, printer, screen)" >&2
      return 1
      ;;
  esac

  local gs_cmd
  gs_cmd="$(command -v gs)" || {
    echo "Error: gs not found in PATH" >&2
    return 1
  }

  local f bak
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "Skipping non-file: $f" >&2
      continue
    fi

    bak="${f}.bak"
    if [[ -e "$bak" ]]; then
      echo "Error: backup already exists, refusing to overwrite: $bak" >&2
      return 1
    fi

    mv "$f" "$bak"
    if "$gs_cmd" -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 \
      "-dPDFSETTINGS=/$preset" -dNOPAUSE -dQUIET -dBATCH \
      -sOutputFile="$f" "$bak"; then
      rm -f "$bak"
      echo "Optimized: $f (preset: $preset)"
    else
      mv "$bak" "$f"
      echo "Error: optimization failed, restored original: $f" >&2
      return 1
    fi
  done
}

main() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") [--preset <name>] <file>..."
    echo ""
    echo "Optimize PDF files using Ghostscript. Creates .bak backup before processing."
    echo ""
    echo "Presets (default: default):"
    echo "  default   - high quality"
    echo "  ebook     - medium quality (good for e-readers)"
    echo "  prepress  - high quality (preserves color, suitable for printing)"
    echo "  printer   - medium quality for printing"
    echo "  screen    - low quality (smallest file)"
    echo ""
    echo "If a .bak file already exists for any input, the command refuses and exits."
    echo "On failure, the original file is restored from backup."
    exit 0
  fi

  gs_pdf_opt "$@"
}

main "$@"
