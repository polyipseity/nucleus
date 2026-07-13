#!/usr/bin/env bash
# nucleus-gs-pdf-opt: Optimize PDF files with Ghostscript (backup/restore).
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

usage() {
  usage_std "$(basename "$0")" "[--preset <name>] [--rm-bak] <file>..." \
    "Optimize PDF files using Ghostscript. Keeps a .bak backup by default."
  cat <<'EOF'

Presets (default: default):
  default   - high quality
  ebook     - medium quality (good for e-readers)
  prepress  - high quality (preserves color, suitable for printing)
  printer   - medium quality for printing
  screen    - low quality (smallest file)

Options:
  --rm-bak  Remove the .bak backup on success (kept by default).

If a .bak file already exists for any input, the command refuses and exits.
On failure, the original file is restored from backup.
EOF
}

gs_pdf_opt() {
  local preset="default"
  local rm_bak=false
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
      --rm-bak)
        rm_bak=true
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

  # Ensure TMPDIR is set for Ghostscript temp files.
  # From macOS sandboxed contexts (do shell script via Services), TMPDIR may not
  # be set and /tmp may not be writable.
  export TMPDIR="${TMPDIR:-$HOME/Library/Caches/nucleus-gs-pdf-opt}"
  mkdir -p "$TMPDIR"

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
      $rm_bak && rm -f "$bak"
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
