#!/usr/bin/env bash
# nucleus-utils: Grouped nucleus user utilities.
#
# Currently provides the optimize-pdf subcommand: optimize PDF files with
# Ghostscript, keeping a .bak backup that is restored automatically if
# optimization fails. Also provides strip-metadata: remove personal
# metadata from Office files using mat2 (OOXML) and exiftool (other formats).
#
# Usage: nucleus-utils <subcommand> [args...]
#   Subcommand: optimize-pdf [--preset <name>] [--rm-bak] <file>...
#   Subcommand: strip-metadata [--rm-bak] <file>...
#   Presets: default, ebook, prepress, printer, screen (default: default).
#
# Env vars: TMPDIR — ghostscript scratch space; falls back to a per-user
# cache dir when unset (macOS Services sandbox omits it).
#
# Exit conditions: refuses when a .bak already exists; restores the original
# and exits 1 if gs/exiftool fails; exits 0 on success.
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
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# usage — Print the full command reference.
# WHY: the help text is the executable contract — it must enumerate every
# subcommand, flag, and preset the parsers accept, so it stays in sync with
# the dispatch and case branches below.
usage() {
  usage_std "$(basename "$$0")" "optimize-pdf [--preset <name>] [--rm-bak] <file>... | strip-metadata [--rm-bak] <file>..." \
    "Grouped nucleus user utilities. Currently: optimize-pdf (optimize PDFs with Ghostscript), strip-metadata (strip file metadata with mat2/exiftool)."
  cat <<'EOF'

Subcommands:
  optimize-pdf [--preset <name>] [--rm-bak] <file>...
              Optimize PDF files using Ghostscript. Keeps a .bak backup by default.

  strip-metadata [--rm-bak] <file>...
              Strip personal metadata from files. Uses mat2 for OOXML
              (.docx/.xlsx/.pptx) and exiftool for other formats.
              Legacy OLE2 files (.doc/.xls/.ppt) are skipped with a warning.

  optimize-pdf presets (default: default):
    default   - high quality
    ebook     - medium quality (good for e-readers)
    prepress  - high quality (preserves color, suitable for printing)
    printer   - medium quality for printing
    screen    - low quality (smallest file)

  Common options:
    --rm-bak  Remove the .bak backup on success (kept by default).

  If a .bak file already exists for any input, the command refuses and exits.
  On failure, the original file is restored from backup.
EOF
}

# do_optimize_pdf — Optimize each input PDF in place via Ghostscript.
# Args: $@ — option/flag pairs followed by input file paths.
# Side effects: renames each input to <file>.bak and writes the optimized
# file back to <file>; removes the .bak only with --rm-bak.
# Preconditions: gs on PATH; TMPDIR set or creatable; no pre-existing .bak
# for any input — the .bak is the only recovery copy if gs fails mid-run.
do_optimize_pdf() {
  local preset="default"
  local rm_bak=false
  local files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
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
  default | ebook | prepress | printer | screen) ;;
  *)
    warn "unknown preset: $preset (valid: default, ebook, prepress, printer, screen)"
    return 1
    ;;
  esac

  # Ensure TMPDIR is set for Ghostscript temp files.
  # From macOS sandboxed contexts (do shell script via Services), TMPDIR may not
  # be set and /tmp may not be writable, so fall back to a per-user cache dir
  # that is guaranteed writable and scoped to this tool.
  export TMPDIR="${TMPDIR:-$HOME/Library/Caches/nucleus-optimize-pdf}"
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

# do_strip_metadata — Strip personal metadata from each input file.
# OOXML files (.docx/.xlsx/.pptx) are handled by mat2, which also cleans
# embedded media metadata recursively. Legacy OLE2 files are skipped
# (neither mat2 nor exiftool can write them). Other formats use exiftool.
# Args: $@ — option/flag pairs followed by input file paths.
# Side effects: renames each input to <file>.bak and writes the stripped
# file back to <file>; removes the .bak only with --rm-bak.
# Preconditions: mat2 or exiftool on PATH (depending on file type);
#   no pre-existing .bak for any input.
do_strip_metadata() {
  local rm_bak=false
  local files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      usage
      return 0
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

  local mat2_cmd
  # check-suppress:suppression_doc: mat2 is optional — OOXML files fall through to warning when absent.
  mat2_cmd="$(command -v mat2 2>/dev/null || true)"
  local et_cmd
  # check-suppress:suppression_doc: exiftool is optional — non-Office files fall through to warning when absent.
  et_cmd="$(command -v exiftool 2>/dev/null || true)"

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

    case "$f" in
    *.docx | *.xlsx | *.pptx)
      if [[ -z "$mat2_cmd" ]]; then
        warn "mat2 not found in PATH, cannot strip OOXML metadata: $f"
        continue
      fi
      # WHY: backup first, then mat2 --inplace on the original — .bak holds the
      # untouched original, so an interrupt leaves either the original or the
      # stripped file, never a half-written one.
      cp -- "$f" "$bak"
      if "$mat2_cmd" --inplace "$f" 2>/dev/null; then
        "$rm_bak" && rm -f "$bak"
        say "stripped metadata: $f"
      else
        mv -f -- "$bak" "$f"
        error "metadata stripping failed, restored original: $f"
        return 1
      fi
      ;;
    *.doc | *.xls | *.ppt)
      warn "skipping legacy OLE2 (no CLI tool can write this format): $f"
      ;;
    *)
      if [[ -z "$et_cmd" ]]; then
        warn "exiftool not found in PATH, cannot strip metadata: $f"
        continue
      fi
      mv "$f" "$bak"
      if "$et_cmd" -all= -overwrite_original -o "$f" "$bak"; then
        "$rm_bak" && rm -f "$bak"
        say "stripped metadata: $f"
      else
        mv "$bak" "$f"
        error "metadata stripping failed, restored original: $f"
        return 1
      fi
      ;;
    esac
  done
}

# main — Entry point: dispatch on the first argument as subcommand.
# WHY: a bare invocation or -h/--help shows help with exit 0 (not an error)
# so the first run is discoverable and harmless.
main() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
  optimize-pdf)
    do_optimize_pdf "$@"
    ;;
  strip-metadata)
    do_strip_metadata "$@"
    ;;
  *)
    error "unknown subcommand: $subcommand"
    usage >&2
    exit 1
    ;;
  esac
}

main "$@"
