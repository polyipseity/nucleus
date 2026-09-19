#!/usr/bin/env bash
# nucleus-utils: Grouped nucleus user utilities.
#
# Currently provides the optimize-pdf subcommand: optimize PDF files with
# Ghostscript, keeping a .bak backup that is restored automatically if
# optimization fails. Also provides strip-metadata: remove personal
# metadata from Office files using mat2 (OOXML) and exiftool (other
# formats). PDF and legacy OLE2 files are skipped and reported. With
# --dialog every input that was not processed is summarized in one modal
# popup after all inputs have been attempted.
# ICC color profiles are preserved for correct color rendering.
#
# Usage: nucleus-utils <subcommand> [args...]
#   Subcommand: optimize-pdf [--preset <name>] [--rm-bak] <file>...
#   Subcommand: strip-metadata [--rm-bak] [--dialog] <file>...
#   Presets: default, ebook, prepress, printer, screen (default: default).
#
# Env vars: TMPDIR — ghostscript scratch space; falls back to a per-user
# cache dir when unset (macOS Services sandbox omits it).
#
# Exit conditions: refuses when a .bak already exists; restores the original
# and exits 1 if gs/exiftool fails; exits 0 on success. strip-metadata
# attempts every input before reporting, so one bad file no longer abandons
# the rest of the selection.
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
  usage_std "$(basename "$$0")" "optimize-pdf [--preset <name>] [--rm-bak] <file>... | strip-metadata [--rm-bak] [--dialog] <file>..." \
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

# _notify — Send a desktop notification if a notification tool is available.
# macOS: osascript display notification; Linux: notify-send.
# Args: $1 — title, $2 — message body.
# check-suppress:suppression_doc: notification tools are optional — best-effort display.
_notify() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    # WHY: title and body are passed as argv, never interpolated into the
    # AppleScript source — a path containing a quote or a backslash would
    # otherwise be a syntax error that the redirect below hides.
    osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$title" "$body" 2>/dev/null || true # check-suppress:suppression_doc: notification is best-effort; failure is non-critical
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${body}" 2>/dev/null || true # check-suppress:suppression_doc: notification is best-effort; failure is non-critical
  fi
}

# _error_report — Print an error message without aborting the run.
# error() returns 1, and this script runs under set -e, so a bare error() call
# ends the process. strip-metadata reports every input that was not processed
# and keeps going: a single unreadable file must not abandon the rest of the
# user's selection.
# WHY: `|| true` is deliberate — the failure is already recorded in the
# per-input report and reflected in the exit status.
_error_report() { error "$@" || true; } # check-suppress:suppression_doc: error() returning 1 is expected; the failure is recorded and reported separately

# _popup — Show a modal dialog that stays on screen until it is dismissed.
# macOS: osascript display dialog; Linux: zenity, then kdialog. When no dialog
# tool is installed the message degrades to _notify.
# Args: $1 — title, $2 — message body.
_popup() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    # WHY: see _notify — argv keeps arbitrary file paths out of the AppleScript source.
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

# _strip_metadata_summary — Render the strip-metadata popup body.
# Args: $1 — inputs processed, $2 — inputs given, $3... — one
# "<reason>|<path>" entry per input that was not processed.
# WHY: the list is capped — a modal dialog has no scrollbar, so an unbounded
# list would grow the window (or be clipped) instead of showing the tail.
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
# ICC color profiles are preserved for correct color rendering.
# Args: $@ — option/flag pairs followed by input file paths.
#   --dialog: report every not-processed input in one modal popup after the
#   run, instead of one notification per input.
# Side effects: renames each input to <file>.bak and writes the stripped
# file back to <file>; removes the .bak only with --rm-bak.
# Preconditions: mat2 or exiftool on PATH (depending on file type);
#   no pre-existing .bak for any input.
# Returns: 1 when any input failed; a failure never aborts the remaining
#   inputs, so the caller still sees the whole selection reported.
do_strip_metadata() {
  local rm_bak=false
  local dialog=false
  local files=()
  # One "<reason>|<path>" entry per input that was not processed, collected
  # across the whole run: a Finder Quick Action hands every selected file to a
  # single invocation, so reporting per file would mean one popup per skip.
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
  # check-suppress:suppression_doc: mat2 is optional — OOXML files fall through to warning when absent.
  mat2_cmd="$(command -v mat2 2>/dev/null || true)"
  local et_cmd
  # check-suppress:suppression_doc: exiftool is optional — non-Office files fall through to warning when absent.
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
      # WHY: backup first, then mat2 --inplace on the original — .bak holds the
      # untouched original, so an interrupt leaves either the original or the
      # stripped file, never a half-written one. --unknown-members keep preserves
      # unsupported embedded content (OLE objects, WMF images) as-is instead of
      # aborting — mat2 has no parser for these formats so they cannot be scrubbed.
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
      # WHY: backup first, then in-place strip on the original — .bak holds the
      # untouched original, so an interrupt leaves either the original or the
      # stripped file, never a half-written one.
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

  # Report once, after every input has been attempted: the --dialog caller has
  # no terminal to read, and it hands the whole selection to this one call.
  if [[ "$dialog" == true && ${#unprocessed[@]} -gt 0 ]]; then
    _popup "strip metadata" "$(_strip_metadata_summary "$processed" "${#files[@]}" "${unprocessed[@]}")"
  fi

  [[ "$failed" -eq 0 ]]
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
