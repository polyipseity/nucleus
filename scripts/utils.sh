#!/usr/bin/env bash
# nucleus-utils: optimize-pdf (Ghostscript) and strip-metadata (mat2/exiftool).
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

# WHY: the help text is the executable contract, so it enumerates every
# subcommand, flag, and preset the parsers accept.
usage() {
  usage_std "$(basename "$0")" "optimize-pdf [--preset <name>] [--rm-bak] <file>... | strip-metadata [--rm-bak] [--dialog] <file>..." \
    "Grouped nucleus user utilities. Currently: optimize-pdf (optimize PDFs with Ghostscript), strip-metadata (strip file metadata with mat2/exiftool)."
  cat <<'EOF'

Subcommands:
  optimize-pdf [--preset <name>] [--rm-bak] <file>...
              Optimize PDF files using Ghostscript. Keeps a .bak backup by default.

  strip-metadata [--rm-bak] [--dialog] <file>...
              Strip personal metadata from files. Uses mat2 for OOXML
              (.docx/.xlsx/.pptx) and exiftool for other formats.
              ICC color profiles are preserved for correct color rendering.
              Legacy OLE2 files (.doc/.xls/.ppt) and PDF files are skipped
              with a warning.

  optimize-pdf presets (default: default):
    default   - high quality
    ebook     - medium quality (good for e-readers)
    prepress  - high quality (preserves color, suitable for printing)
    printer   - medium quality for printing
    screen    - low quality (smallest file)

  Common options:
    --rm-bak  Remove the .bak backup on success (kept by default).
    --dialog  Show one popup listing the inputs that were not processed
              (strip-metadata only). Needed by GUI callers: a Finder Quick
              Action discards the action's stdout and stderr, so a modal
              dialog is the only feedback the user cannot miss.

  Inputs that cannot be processed are listed at the end; with --dialog the list
  is shown in a modal popup. If a .bak file already exists for an input, that
  input is refused. On failure, the original file is restored from backup.
EOF
}

# WHY: title and body are passed as argv, never interpolated into the
# AppleScript source. A path holding a quote or backslash would otherwise be
# a syntax error that the redirect below hides.
# check-suppress:suppression_doc: notification tools are optional, the display is best-effort.
_notify() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    # WHY: title and body are passed as argv, never interpolated into the
    # AppleScript source. A path holding a quote or a backslash would otherwise
    # be a syntax error that the redirect below hides.
    osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$title" "$body" 2>/dev/null || true # check-suppress:suppression_doc: notification is best-effort; failure is non-critical
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${body}" 2>/dev/null || true # check-suppress:suppression_doc: notification is best-effort; failure is non-critical
  fi
}

# error() returns 1 and the script runs under set -e, so a bare error() call
# would end the process. strip-metadata reports every input it could not process
# and keeps going, so one unreadable file must not abandon the rest.
_error_report() { error "$@" || true; } # check-suppress:suppression_doc: error() returning 1 is expected; the failure is recorded and reported separately

# Falls back to _notify when no dialog tool is installed.
_popup() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    # WHY: see _notify, argv keeps arbitrary file paths out of the AppleScript source.
    osascript -e 'on run argv' \
      -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon caution' \
      -e 'end run' "$title" "$body" 2>/dev/null || true # check-suppress:suppression_doc: the dialog is best-effort and stderr already carries the same report
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --warning --title="${title}" --text="${body}" 2>/dev/null || true # check-suppress:suppression_doc: the dialog is best-effort and stderr already carries the same report
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "${title}" --msgbox "${body}" 2>/dev/null || true # check-suppress:suppression_doc: the dialog is best-effort and stderr already carries the same report
    return 0
  fi
  _notify "${title}" "${body}"
}

# WHY: the list is capped, since a modal dialog has no scrollbar and an
# unbounded list would grow the window instead of showing the tail.
_strip_metadata_summary() {
  local processed="$1" total="$2"
  shift 2
  local -a entries=("$@")
  local shown=0 max=10 entry reason path
  printf 'Stripped metadata from %s of %s file(s).\n\nNot processed (%s):\n' \
    "$processed" "$total" "${#entries[@]}"
  for entry in "${entries[@]}"; do
    if [[ "$shown" -ge "$max" ]]; then
      printf '... and %s more.\n' "$((${#entries[@]} - shown))"
      break
    fi
    reason="${entry%%|*}"
    path="${entry#*|}"
    printf '• %s — %s\n' "$(basename -- "$path")" "$reason"
    shown=$((shown + 1))
  done
}

# The .bak is the only recovery copy if gs fails mid-run, so an existing one is
# refused rather than overwritten.
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

  # A macOS Services sandbox may leave TMPDIR unset and /tmp unwritable, so the
  # fallback is a per-user cache dir.
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

    # WHY: move-then-optimize gives an atomic recovery point. gs reads the .bak and
    # writes the original path, so an interrupt leaves either the untouched
    # original or the optimized file, never a half-written one.
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

# mat2 handles OOXML, exiftool the rest. Legacy OLE2 and PDF are skipped
# because no CLI tool can write them, and ICC profiles are preserved rather
# than stripped. A failure never abandons the remaining inputs.
do_strip_metadata() {
  local rm_bak=false
  local dialog=false
  local files=()
  # One "<reason>|<path>" entry per input that was not processed, collected
  # across the whole run, because a Finder Quick Action hands every selected
  # file to a single invocation.
  local -a unprocessed=()
  local processed=0
  local failed=0

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
    --dialog)
      dialog=true
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
  # check-suppress:suppression_doc: mat2 is optional: OOXML files fall through to warning when absent.
  mat2_cmd="$(command -v mat2 2>/dev/null || true)"
  local et_cmd
  # check-suppress:suppression_doc: exiftool is optional: non-Office files fall through to warning when absent.
  et_cmd="$(command -v exiftool 2>/dev/null || true)"

  local f bak
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      warn "skipping non-file: $f"
      unprocessed+=("not a file|$f")
      continue
    fi

    bak="${f}.bak"
    if [[ -e "$bak" ]]; then
      _error_report "backup already exists, refusing to overwrite: $bak"
      unprocessed+=("a .bak backup already exists|$f")
      failed=$((failed + 1))
      continue
    fi

    case "$f" in
    *.docx | *.xlsx | *.pptx)
      if [[ -z "$mat2_cmd" ]]; then
        warn "mat2 not found in PATH, cannot strip OOXML metadata: $f"
        unprocessed+=("mat2 is not installed|$f")
        continue
      fi
      # WHY: backup first, then mat2 --inplace on the original, so an interrupt
      # leaves either the original or the stripped file. --unknown-members keep
      # preserves unsupported embedded content (OLE objects, WMF images) rather
      # than aborting, since mat2 has no parser for those formats.
      cp -- "$f" "$bak"
      if "$mat2_cmd" --inplace --unknown-members keep "$f" 2>/dev/null; then
        "$rm_bak" && rm -f "$bak"
        processed=$((processed + 1))
        say "stripped metadata: $f"
        _notify "strip metadata" "Stripped metadata: $f"
      else
        mv -f -- "$bak" "$f"
        _error_report "metadata stripping failed, restored original: $f"
        unprocessed+=("metadata stripping failed, original restored|$f")
        failed=$((failed + 1))
      fi
      ;;
    *.doc | *.xls | *.ppt)
      warn "skipping legacy OLE2 (no CLI tool can write this format): $f"
      unprocessed+=("legacy OLE2 is not supported|$f")
      if [[ "$dialog" == false ]]; then
        _notify "strip metadata" "Skipped legacy OLE2 (unsupported format): $f"
      fi
      ;;
    *.pdf)
      warn "skipping PDF (strip-metadata does not support PDF files): $f"
      unprocessed+=("PDF files are not supported|$f")
      if [[ "$dialog" == false ]]; then
        _notify "strip metadata" "Skipped PDF (not supported): $f"
      fi
      ;;
    *)
      if [[ -z "$et_cmd" ]]; then
        warn "exiftool not found in PATH, cannot strip metadata: $f"
        unprocessed+=("exiftool is not installed|$f")
        continue
      fi
      # WHY: backup first, then an in-place strip, so an interrupt leaves either the
      # original or the stripped file.
      cp -- "$f" "$bak"
      if "$et_cmd" -all= --icc_profile:all -overwrite_original "$f"; then
        "$rm_bak" && rm -f "$bak"
        processed=$((processed + 1))
        say "stripped metadata: $f"
        _notify "strip metadata" "Stripped metadata: $f"
      else
        mv -f -- "$bak" "$f"
        _error_report "metadata stripping failed, restored original: $f"
        unprocessed+=("metadata stripping failed, original restored|$f")
        failed=$((failed + 1))
      fi
      ;;
    esac
  done

  # Report once, after every input has been attempted, because the --dialog
  # caller has no terminal to read.
  if [[ "$dialog" == true && ${#unprocessed[@]} -gt 0 ]]; then
    _popup "strip metadata" "$(_strip_metadata_summary "$processed" "${#files[@]}" "${unprocessed[@]}")"
  fi

  [[ "$failed" -eq 0 ]]
}

# WHY: a bare invocation or -h/--help shows help with exit 0, so the first run
# is discoverable and harmless.
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
