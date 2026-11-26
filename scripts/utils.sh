#!/usr/bin/env bash
# nucleus-utils: optimize-pdf (Ghostscript), strip-metadata (mat2/exiftool),
# harness notify/approval/filter/drive, and safe-delete-guard.
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
# shellcheck source=../src/scripts/lib/bash-guard.sh
. "$SCRIPT_DIR/../src/scripts/lib/bash-guard.sh"
bash_guard_require 5 1 utils

# shellcheck source=../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# WHY: the help text is the executable contract, so it enumerates every
# subcommand, flag, and preset the parsers accept.
usage() {
  usage_std "$(basename "$0")" \
    "optimize-pdf [--preset <name>] [--rm-bak] <file>... | strip-metadata [--rm-bak] [--dialog] <file>... | harness <verb> [args...]" \
    "Grouped nucleus user utilities. optimize-pdf/strip-metadata process files; harness groups notification, approval, filter, drive, sandbox reporting, deletion checking, and model merge verbs."
  cat <<'EOF'

  -h|--help  Show usage.

Subcommands:
  optimize-pdf [--preset <name>] [--rm-bak] <file>...
              Optimize PDF files using Ghostscript. Keeps a .bak backup by default.

  strip-metadata [--rm-bak] [--dialog] <file>...
              Strip personal metadata from files. Uses mat2 for OOXML
              (.docx/.xlsx/.pptx) and exiftool for other formats.
              ICC color profiles are preserved for correct color rendering.
              Legacy OLE2 files (.doc/.xls/.ppt) and PDF files are skipped
              with a warning.

  harness <verb> [args...]
              Harness bridge and guard entry points. Run `nucleus-utils harness --help` for verbs.

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

usage_harness() {
  cat <<'EOF'
usage: nucleus-utils harness <verb> [args...]

Harness bridge and guard verbs.

Verbs:
  send-notification <harness> <event> [text]
              Normalize a harness lifecycle event into a Hermes notification.
              Dispatches to src/scripts/notify/harness/send-notification.sh.

  decide-call <harness>
              Read a harness hook payload on stdin and print a decision document.
              Dispatches to src/scripts/notify/harness/decide-call.sh.

  request-approval <harness> <tool> <summary> [timeout-seconds]
              Request an approval decision for a harness tool call.
              Dispatches to src/scripts/notify/harness/request-approval.sh.

  continue-turn <harness>
              End a harness turn: notify and inject one queued remote prompt.
              Dispatches to src/scripts/notify/harness/continue-turn.sh.

  report-sandbox <harness> [--format <text|claude|cursor|check>] [--session-id <id>]
              Detect the current sandbox state, compare it with the recorded
              state for the harness session, emit context on a change or first
              observation, and update the record.
    --format <text|claude|cursor|check>  Output format.
    --session-id <id>  Harness session identifier.

  check-deletion [--settings <json>] [--command <text>] [--hook]
              Evaluate deletion commands against the safe-delete policy.
              Dispatches to src/scripts/notify/filters/safe-delete.ts.
    --settings <json>  Filter settings JSON.
    --command <text>   Command text to evaluate.
    --hook             Read hook payload on stdin and emit hook protocol output.

  merge-models [--check] [--registry <path>] [--home <dir>] [--repo-root <dir>] [--harness <id>]
              Merge LiteLLM gateway model aliases into harness config files.
              # check-suppress:config-method: method 4 (runtime direct read) -- registry is read by merge-harness-models.py at runtime.
              Registry: src/modules/configs/harness-models.json.
    --check            Verify merged state without writing; exit non-zero on drift.
    --registry <path>  Registry JSON path.
    --home <dir>       Home directory for resolving target paths.
    --repo-root <dir>  Repository root for resolving payload and registry paths.
    --harness <id>     Only process this harness id (repeatable).
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

_sc_sandboxed_context_block="You are inside the srt sandbox. The repo and the granted scratch paths work normally, but the fence is real: network destinations and Unix sockets are allowlisted, some paths are read-only, git config hooks and secrets are protected, and deletions land in the Trash through the safe wrapper (Finder 'Put Back' is unavailable because Apple Events are denied). If a command fails with a permission or socket error, assume the fence before assuming a bug, say what you need, and use \`pi-unrestricted\` only when the task genuinely needs the unsandboxed host."
_sc_unsandboxed_context_block="You are outside the srt sandbox, so the full host is reachable. That is more power than the sandboxed default, so treat deletions, secrets, and network calls with extra care; the safe-delete rules still apply, and a command that worked here may be blocked in the sandbox when you switch back."

_sc_detect_sandbox() {
  local raw="${SANDBOX_RUNTIME-}"
  if [ "${SANDBOX_RUNTIME+set}" != "set" ]; then
    printf 'unsandboxed\tSANDBOX_RUNTIME unset\n'
    return 0
  fi
  if [ -z "$raw" ]; then
    printf 'unsandboxed\tSANDBOX_RUNTIME empty string\n'
    return 0
  fi
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
  0 | false)
    printf 'unsandboxed\tSANDBOX_RUNTIME=%s (false-like)\n' "$raw"
    ;;
  *)
    printf 'sandboxed\tSANDBOX_RUNTIME=%s\n' "$raw"
    ;;
  esac
}

_sc_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

_sc_iso_days_ago() {
  local days="$1"
  if date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  if date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  python3 - "$days" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
}

_sc_read_inject_on_change() {
  local config_file="$HOME/.local/state/nucleus/config.json"
  if [ ! -f "$config_file" ]; then
    printf 'true\n'
    return 0
  fi
  local value
  if ! value="$(jq -r '
    if (.["sandbox-context"] | type) == "object" and (.["sandbox-context"]["inject-on-change"] | type) == "boolean"
    then .["sandbox-context"]["inject-on-change"]
    else true
    end
  ' "$config_file" 2>/dev/null)"; then
    printf 'true\n'
    return 0
  fi
  case "$value" in
  false) printf 'false\n' ;;
  *) printf 'true\n' ;;
  esac
}

_sc_extract_session_id() {
  local payload="$1" explicit="$2"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -z "$payload" ]; then
    printf 'default\n'
    return 0
  fi
  local sid
  sid="$(printf '%s' "$payload" | jq -r '
    if type != "object" then empty
    else (.session_id // .sessionId // .sessionID // .conversation_id // .conversationId // empty)
    end
    | select(type == "string" and length > 0)
  ' 2>/dev/null || true)" # check-suppress:suppression_doc: a malformed or non-object payload yields no session id; default is used.
  if [ -z "$sid" ]; then
    printf 'default\n'
  else
    printf '%s\n' "$sid"
  fi
}

_sc_change_notice() {
  local from="$1" to="$2"
  if [ "$from" = "sandboxed" ] && [ "$to" = "unsandboxed" ]; then
    printf 'Sandbox state changed: sandboxed -> unsandboxed. %s\n' "$_sc_unsandboxed_context_block"
  elif [ "$from" = "unsandboxed" ] && [ "$to" = "sandboxed" ]; then
    printf 'Sandbox state changed: unsandboxed -> sandboxed. %s\n' "$_sc_sandboxed_context_block"
  else
    printf 'Sandbox state changed: %s -> %s.\n' "$from" "$to"
  fi
}

_sc_full_status_block() {
  local state="$1"
  if [ "$state" = "sandboxed" ]; then
    printf '%s\n' "$_sc_sandboxed_context_block"
  else
    printf '%s\n' "$_sc_unsandboxed_context_block"
  fi
}

_sc_emit_message() {
  local format="$1" message="$2"
  case "$format" in
  text)
    printf '%s' "$message"
    ;;
  claude)
    jq -cn --arg ctx "$message" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
    ;;
  cursor | check)
    # Cursor prompt-visible injection protocol is unverified in this
    # repository, so cursor format records without emitting. check always
    # records without emitting.
    ;;
  *)
    printf '%s' "$message"
    ;;
  esac
}

do_sandbox_context() {
  require_command jq

  local harness="" format="text" session_id_arg=""
  if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
    usage
    return 0
  fi
  if [ $# -eq 0 ]; then
    error "report-sandbox requires a harness name"
    return 1
  fi
  harness="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
    --format)
      format="${2-}"
      shift 2
      ;;
    --format=*)
      format="${1#*=}"
      shift
      ;;
    --session-id)
      session_id_arg="${2-}"
      shift 2
      ;;
    --session-id=*)
      session_id_arg="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      error "unknown report-sandbox option: $1"
      return 1
      ;;
    esac
  done

  case "$format" in
  text | claude | cursor | check) ;;
  *)
    error "unknown report-sandbox format: $format"
    return 1
    ;;
  esac

  local payload=""
  if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null || true)" # check-suppress:suppression_doc: stdin may be empty or unreadable in hook contexts; no payload means default session id.
  fi

  local session_id
  session_id="$(_sc_extract_session_id "$payload" "$session_id_arg")"

  local detected state evidence
  detected="$(_sc_detect_sandbox)"
  state="${detected%%$'\t'*}"
  evidence="${detected#*$'\t'}"

  local inject_on_change
  inject_on_change="$(_sc_read_inject_on_change)"

  local root record_dir record_file
  root="$(derive_nucleus_user_root)"
  record_dir="$root/state/harness-bridge/sandbox"
  record_file="$record_dir/${harness}.json"

  local prior_state="unknown" corrupt=0 existing_json=""
  if [ -f "$record_file" ]; then
    if existing_json="$(cat "$record_file" 2>/dev/null)" &&
      printf '%s' "$existing_json" | jq -e 'type == "object" and .version == 1 and (.sessions | type) == "object"' >/dev/null 2>&1; then
      prior_state="$(printf '%s' "$existing_json" | jq -r --arg sid "$session_id" '
        .sessions[$sid].state // "unknown"
        | if . == "sandboxed" or . == "unsandboxed" then . else "unknown" end
      ' 2>/dev/null || printf 'unknown')"
    else
      corrupt=1
      warn "sandbox-context: corrupt or unreadable record '$record_file'; treating prior state as unknown"
    fi
  fi

  local message="" should_emit=0 should_record=0
  if [ "$prior_state" = "unknown" ]; then
    message="$(_sc_full_status_block "$state")"
    should_emit=1
    should_record=1
  elif [ "$prior_state" = "$state" ]; then
    # Unchanged: emit nothing and do not rewrite the file.
    return 0
  else
    message="$(_sc_change_notice "$prior_state" "$state")"
    should_emit=1
    should_record=1
  fi

  if [ "$should_record" -eq 1 ]; then
    local now cutoff base_json
    now="$(_sc_iso_now)"
    cutoff="$(_sc_iso_days_ago 30)"

    if [ "$corrupt" -eq 1 ] || [ ! -f "$record_file" ]; then
      base_json='{"version":1,"sessions":{}}'
    else
      base_json="$existing_json"
    fi

    mkdir -p "$record_dir"
    local tmp_file
    tmp_file="$record_file.tmp.$$"
    if ! printf '%s' "$base_json" | jq --arg sid "$session_id" --arg st "$state" --arg ev "$evidence" --arg at "$now" --arg cutoff "$cutoff" '
      .version = 1
      | .sessions = ((.sessions // {}) | if type == "object" then . else {} end)
      | .sessions[$sid] = {state: $st, evidence: $ev, observedAt: $at}
      | .sessions = (
          .sessions
          | to_entries
          | map(select((.value.observedAt // "") >= $cutoff))
          | sort_by(.value.observedAt // "")
          | if length > 50 then .[-50:] else . end
          | from_entries
        )
    ' >"$tmp_file" 2>/dev/null; then
      rm -f "$tmp_file"
      warn "sandbox-context: could not write record '$record_file'"
      # Do not emit on write failure? The decision was made; better to still emit
      # if we were going to, but record is lost. Brief states "record..." as part
      # of behavior; write failure is an operational issue. I'll warn and continue
      # to emit if appropriate.
    else
      if ! mv -f "$tmp_file" "$record_file"; then
        rm -f "$tmp_file"
        warn "sandbox-context: could not publish record '$record_file'"
      fi
    fi
  fi

  if [ "$should_emit" -eq 1 ] && [ "$inject_on_change" = "true" ]; then
    _sc_emit_message "$format" "$message"
  fi
  return 0
}

do_harness() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage_harness
    return 0
  fi

  local verb="$1"
  shift

  case "$verb" in
  send-notification)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/send-notification.sh" "$@"
    ;;
  decide-call)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/decide-call.sh" "$@"
    ;;
  request-approval)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/request-approval.sh" "$@"
    ;;
  continue-turn)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/continue-turn.sh" "$@"
    ;;
  report-sandbox)
    do_sandbox_context "$@"
    ;;
  check-deletion)
    exec "$SCRIPT_DIR/../src/scripts/notify/filters/safe-delete.ts" "$@"
    ;;
  merge-models)
    exec python3 "$SCRIPT_DIR/../src/scripts/agents/merge-harness-models.py" "$@"
    ;;
  *)
    error "unknown harness verb: $verb" || true # check-suppress:suppression_doc: print usage after error; return below carries the non-zero contract
    usage_harness >&2
    return 1
    ;;
  esac
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
  harness)
    do_harness "$@"
    ;;
  # WHY: A1 nests harness verbs; A2 sweeps external references. Keep the old
  # top-level names dispatching to the same implementations so existing hooks,
  # tests, and callers remain functional during the slice.
  harness-notify)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/send-notification.sh" "$@"
    ;;
  harness-approval)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/request-approval.sh" "$@"
    ;;
  harness-filter)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/decide-call.sh" "$@"
    ;;
  harness-drive)
    exec "$SCRIPT_DIR/../src/scripts/notify/harness/continue-turn.sh" "$@"
    ;;
  sandbox-context)
    do_sandbox_context "$@"
    ;;
  safe-delete-guard)
    exec "$SCRIPT_DIR/../src/scripts/notify/filters/safe-delete.ts" "$@"
    ;;
  *)
    error "unknown subcommand: $subcommand"
    usage >&2
    exit 1
    ;;
  esac
}

main "$@"
