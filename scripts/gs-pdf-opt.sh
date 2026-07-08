#!/usr/bin/env bash
# nucleus-gs-pdf-opt: Optimize PDF files with Ghostscript (backup/restore).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[--preset <name>] <file>..." \
    "Optimize PDF files using Ghostscript. Creates .bak backup before processing."
  cat <<'EOF'

Presets (default: default):
  default   - high quality
  ebook     - medium quality (good for e-readers)
  prepress  - high quality (preserves color, suitable for printing)
  printer   - medium quality for printing
  screen    - low quality (smallest file)

If a .bak file already exists for any input, the command refuses and exits.
On failure, the original file is restored from backup.
EOF
}

gs_pdf_opt() {
  local preset="default"
  local files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
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
        warn "unknown option: $1"
        return 1
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    usage >&2
    return 1
  fi

  case "$preset" in
    default|ebook|prepress|printer|screen) ;;
    *)
      warn "unknown preset: $preset (valid: default, ebook, prepress, printer, screen)"
      return 1
      ;;
  esac

  local gs_cmd
  gs_cmd="$(command -v gs)" || {
    error "gs not found in PATH"
    return 1
  }

  local f bak
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      warn "skipping non-file: $f"
      continue
    fi

    bak="${f}.bak"
    if [[ -e "$bak" ]]; then
      error "backup already exists, refusing to overwrite: $bak"
      return 1
    fi

    mv "$f" "$bak"
    if "$gs_cmd" -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 \
      "-dPDFSETTINGS=/$preset" -dNOPAUSE -dQUIET -dBATCH \
      -sOutputFile="$f" "$bak"; then
      rm -f "$bak"
      say "optimized: $f (preset: $preset)"
    else
      mv "$bak" "$f"
      error "optimization failed, restored original: $f"
      return 1
    fi
  done
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  gs_pdf_opt "$@"
}

main "$@"
