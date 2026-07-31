#!/usr/bin/env bash
# nucleus-gs-pdf-opt: Optimize PDF files with Ghostscript, keeping a .bak
# backup that is restored automatically if optimization fails.
#
# Usage: nucleus-gs-pdf-opt [--preset <name>] [--rm-bak] <file>...
# Presets: default, ebook, prepress, printer, screen (default: default).
#
# Env vars: TMPDIR — ghostscript scratch space; falls back to a per-user
# cache dir when unset (macOS Services sandbox omits it).
#
# Exit conditions: refuses when a .bak already exists; restores the original
# and exits 1 if gs fails; exits 0 on success.
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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# usage — Print the help text; shown on -h/--help, unknown options, or
# missing file arguments.
# WHY: help doubles as the contract for supported presets and flags, so it
# must stay in sync with the case branches in gs_pdf_opt below.
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

# gs_pdf_opt — Optimize each input PDF in place via Ghostscript.
# Args: $@ — option/flag pairs followed by input file paths.
# Side effects: renames each input to <file>.bak and writes the optimized
# file back to <file>; removes the .bak only with --rm-bak.
# Preconditions: gs on PATH; TMPDIR set or creatable; no pre-existing .bak
# for any input — the .bak is the only recovery copy if gs fails mid-run.
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

  # WHY: presets are validated up front (never passed to gs blindly) so a
  # typo fails fast before any file is touched.
  case "$preset" in
    default|ebook|prepress|printer|screen) ;;
    *)
      warn "unknown preset: $preset (valid: default, ebook, prepress, printer, screen)"
      return 1
      ;;
  esac

  # Ensure TMPDIR is set for Ghostscript temp files.
  # From macOS sandboxed contexts (do shell script via Services), TMPDIR may not
  # be set and /tmp may not be writable, so fall back to a per-user cache dir
  # that is guaranteed writable and scoped to this tool.
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

    # WHY: move-then-optimize gives an atomic recovery point — gs reads the
    # .bak and writes the original path, so an interrupt leaves either the
    # untouched original or the optimized file, never a half-written one.
    mv "$f" "$bak"
    if "$gs_cmd" -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 \
      "-dPDFSETTINGS=/$preset" -dNOPAUSE -dQUIET -dBATCH \
      -sOutputFile="$f" "$bak"; then
      # WHY: the .bak is kept by default so a later quality regression can be
      # reverted; --rm-bak deletes it only after a verified success.
      "$rm_bak" && rm -f "$bak"
      say "optimized: $f (preset: $preset)"
    else
      mv "$bak" "$f"
      error "optimization failed, restored original: $f"
      return 1
    fi
  done
}

# main — Entry point: print help on bare invocation, else delegate.
# WHY: a bare invocation shows help with exit 0 (not an error) so the first
# run is discoverable and harmless.
main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  gs_pdf_opt "$@"
}

main "$@"
