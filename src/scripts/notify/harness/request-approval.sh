#!/usr/bin/env bash
# Requests an approval decision for a harness tool call from the enabled sources.
#
#   nucleus-utils harness request-approval <harness> <tool> <summary> [timeout-seconds]
#       Prints one JSON decision document:
#         {"version":1,"decision":"allow"|"deny"|"ask","reason":"…",
#          "source":"prompt"|"hermes"|"all-timeouts"|"resolver-error"|"none",
#          "timeouts":{"hermes":300,"prompt":600},"timedOutSources":[…]}
#       Harness adapters render that document in their own vocabulary; there is
#       no plain-word mode and no per-harness shape.
#
# `ask` means "no source decided" and the harness falls back to its own local
# prompt. A resolver error or every source timing out is a typed deny that names
# the reason. Every path prints a document and exits 0, because some harnesses
# treat a failed hook as a denial.
#
# ~/.local/state/nucleus/config.json:
#   harness-notify.enable                       boolean, default true; false
#                                               disables the whole bridge and
#                                               answers `ask` at once
#   harness-approval.sources                    list of sources, default
#                                               ["prompt","hermes"]; an empty
#                                               list disables the gate and answers
#                                               `ask` at once
#   harness-approval.timeout-seconds.<source>   seconds per source, default
#                                               300 for hermes, 600 for prompt
#
# Sources are independent and race when more than one is enabled; the first
# answer wins and the other is dropped.
#   prompt  asks in the terminal the hook runs under, over /dev/tty. A hook
#           started without a terminal (a GUI editor, a service) answers `ask`
#           instead of reading a denial into its own silence. The terminal is
#           shared with the harness, so the answer is a line: only Enter decides,
#           and a keystroke meant for the harness TUI is never read as one.
#   hermes  publishes a request under <USER root>/state/harness-bridge and waits
#           for `/harness approve <id>` or `/harness deny <id>` on a channel.
#
# A timeout of 0 waits until an answer arrives, so the harness's own hook timeout
# is the ceiling: the hook files declare 3600 s, which outlasts any human answer
# and still ends a session that nobody is watching. The document always reports
# the contract bounds from the schema, not a caller's override of the wait.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../lib/bash-guard.sh
. "$SCRIPT_DIR/../../lib/bash-guard.sh"
bash_guard_require 5 1 request-approval
# shellcheck source=../../lib/lib.sh
. "$SCRIPT_DIR/../../lib/lib.sh"
# WHY the shared library, not a log path: nucleus-logs owns the log root, the
# line format, and the append, so the gate cannot drift from the log it writes
# into.
# shellcheck source=../../lib/logs.sh
. "$SCRIPT_DIR/../../lib/logs.sh"
# shellcheck source=../../lib/harness-audit.sh
. "$SCRIPT_DIR/../../lib/harness-audit.sh"

_ha_start_ms="$(harness_audit_now_ms)"
# Which source answered: the audit line records it, and `none` means no source
# decided and the harness fell back to its own prompt.
_ha_decided_by=""
# Set once the Hermes request is published, so the audit line can be annotated by
# id; an early exit has no request and the writer mints an id instead.
_ha_id=""
# Contract fields carried to the single document printed at the exit.
_ha_reason=""
_ha_source="none"
_ha_timed_out='[]'

_ha_usage() {
  warn "usage: nucleus-utils harness request-approval <harness> <tool> <summary> [timeout-seconds]"
}

_ha_harness="${1-}"
_ha_tool="${2-}"
_ha_summary="${3-}"
_ha_timeout_arg="${4-}"

# WHY jq: the six fields and their order are the wire contract, and jq quotes
# a reason that came from a remote response without a second escaping path.
_ha_render() {
  jq -cnM \
    --arg decision "$_ha_decision" \
    --arg reason "$_ha_reason" \
    --arg source "$_ha_source" \
    --argjson timedOutSources "$_ha_timed_out" \
    '{version: 1, decision: $decision, reason: $reason, source: $source,
      timeouts: {hermes: 300, prompt: 600}, timedOutSources: $timedOutSources}'
}

_ha_mark_timeout() { # <source>
  _ha_timed_out="$(jq -cnM --arg name "$1" --argjson list "$_ha_timed_out" \
    '$list + [$name] | unique')"
}

_ha_root="$(derive_nucleus_user_root)"

# Every path ends here: the decision is logged (hooks run invisibly, so what was
# asked and how it was answered has to be recoverable) and the process exits 0.
_ha_finish() { # <decision> <reason> <source>
  case "${1-}" in
  allow | deny) _ha_decision="$1" ;;
  *) _ha_decision="ask" ;;
  esac
  _ha_reason="${2:-no approval source answered}"
  _ha_source="${3:-none}"
  _ha_decided_by="$_ha_source"
  # WHY a subshell: nucleus-logs refuses an unusable event by exiting, and a
  # hook that prints nothing reads as a denial in Copilot, so a failed append
  # must not swallow the answer. Best-effort in both directions.
  if ! (
    _ha_audit_summary="$_ha_summary"
    if [ -n "$_ha_tool" ]; then
      _ha_audit_summary="$_ha_tool: $_ha_summary"
    fi
    _ha_audit_summary="$(printf '%s\n' "$_ha_audit_summary" | harness_audit_summary)"
    # WHY the request text: the gate never sees the harness payload, so the tool
    # and the summary it was asked about are the raw input it can vouch for.
    _ha_audit_digest="$(printf '%s\t%s' "$_ha_tool" "$_ha_summary" | harness_audit_digest)" || exit 1
    harness_audit_log approval "$_ha_harness" "$_ha_decision" \
      "$_ha_source" '' '' \
      "$(($(harness_audit_now_ms) - _ha_start_ms))" \
      "$_ha_audit_summary" "$_ha_audit_digest" "$_ha_id"
  ); then
    warn "could not write the harness audit log"
  fi
  _ha_render
  exit 0
}

_ha_finish_error() { # <reason>
  _ha_finish deny "$1" resolver-error
}

if [ -z "$_ha_harness" ]; then
  _ha_usage
  _ha_finish_error "harness-approval requires a harness name"
fi

# Every caller passes all three arguments, and an empty tool means the caller
# got its own arguments wrong.
if [ -z "$_ha_tool" ]; then
  _ha_usage
  _ha_finish_error "harness-approval requires a tool name"
fi

_ha_defaults='{"harness-notify":{"enable":true},"harness-approval":{"sources":["prompt","hermes"],"timeout-seconds":{"hermes":300,"prompt":600}}}'
_ha_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  # WHY: an unreadable config takes the unparsable exit with its message, since
  # a hook dying under `set -e` prints no decision and Copilot reads that as a
  # denial.
  if ! _ha_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"; then
    warn "could not read nucleus config"
    _ha_finish_error "could not read nucleus config"
  fi
fi
if ! _ha_config="$(
  jq -c --argjson defaults "$_ha_defaults" --argjson user "$_ha_user_config" \
    '$defaults * { "harness-notify": ($user["harness-notify"] // {}), "harness-approval": ($user["harness-approval"] // {}) }' <<<'{}'
)"; then
  warn "could not parse nucleus config"
  _ha_finish_error "could not parse nucleus config"
fi

if [ "$(jq -r '."harness-notify".enable' <<<"$_ha_config")" != "true" ]; then
  _ha_finish ask "harness notifications are disabled" none
fi

# WHY: the sources are the gate. None enabled keeps the hooks wired (one config
# key re-enables them) while every tool call is answered `ask` and the harness
# keeps its own prompt.
_ha_prompt=0
_ha_hermes=0
if ! _ha_sources="$(jq -r '."harness-approval".sources[]' <<<"$_ha_config")"; then
  warn "harness-approval.sources is not a list of source names"
  _ha_finish_error "harness-approval.sources is not a list"
fi
# WHY unquoted: jq printed one source per line and the loop wants the words, not
# the newlines.
for _ha_source_name in $_ha_sources; do
  case "$_ha_source_name" in
  prompt) _ha_prompt=1 ;;
  hermes) _ha_hermes=1 ;;
  *)
    warn "unknown harness-approval source '$_ha_source_name'"
    _ha_finish_error "unknown harness-approval source '$_ha_source_name'"
    ;;
  esac
done
if [ "$_ha_prompt" -eq 0 ] && [ "$_ha_hermes" -eq 0 ]; then
  _ha_finish ask "no approval sources enabled" none
fi

_ha_timeout_prompt=0
_ha_timeout_hermes=0
for _ha_name in prompt hermes; do
  if ! _ha_value="$(jq -r --arg name "$_ha_name" '."harness-approval"."timeout-seconds"[$name] // 0' <<<"$_ha_config")"; then
    warn "could not read harness-approval.timeout-seconds.$_ha_name"
    _ha_finish_error "could not read harness-approval.timeout-seconds.$_ha_name"
  fi
  case "$_ha_value" in
  '' | *[!0-9]*)
    warn "harness-approval.timeout-seconds.$_ha_name is not a whole number of seconds"
    _ha_finish_error "harness-approval.timeout-seconds.$_ha_name is not a whole number of seconds"
    ;;
  esac
  case "$_ha_name" in
  prompt) _ha_timeout_prompt="$_ha_value" ;;
  hermes) _ha_timeout_hermes="$_ha_value" ;;
  esac
done

# A positional override replaces every source's own timeout, which is how a
# caller bounds the whole wait without knowing the configured sources.
if [ -n "$_ha_timeout_arg" ]; then
  case "$_ha_timeout_arg" in
  *[!0-9]*)
    warn "the timeout argument must be a whole number of seconds"
    _ha_finish_error "the timeout argument must be a whole number of seconds"
    ;;
  esac
  _ha_timeout_prompt="$_ha_timeout_arg"
  _ha_timeout_hermes="$_ha_timeout_arg"
fi

_ha_dir="$_ha_root/state/harness-bridge"
_ha_requests="$_ha_dir/requests"
_ha_responses="$_ha_dir/responses"
_ha_id=""
_ha_request=""
_ha_response=""

if [ "$_ha_hermes" -eq 1 ]; then
  # WHY: the state tree is the first thing created under the USER root, so an
  # unwritable root fails here. The typed deny names the failure instead of
  # letting `set -e` end the run without a document.
  if ! mkdir -p "$_ha_requests" "$_ha_responses"; then
    warn "could not create the harness-bridge state directory"
    _ha_finish_error "could not create the harness-bridge state directory"
  fi

  # WHY: a harness killed mid-poll leaves a request that can never be answered,
  # and an interrupted publish leaves a .tmp companion; both would otherwise
  # stay in `/harness status` forever. The window is four times the longest
  # finite wait, so a slow-but-live approval survives, and the hook ceiling when
  # every source waits indefinitely, since a zero window would sweep the very
  # request this run is waiting on.
  _ha_window=0
  for _ha_value in "$_ha_timeout_prompt" "$_ha_timeout_hermes"; do
    if [ "$_ha_value" -gt "$_ha_window" ]; then
      _ha_window="$_ha_value"
    fi
  done
  if [ "$_ha_window" -eq 0 ]; then
    _ha_window=3600
  else
    _ha_window=$((_ha_window * 4))
  fi
  # WHY best-effort: this call's request file is still written and /harness
  # status stays correct for new entries.
  if ! find "$_ha_requests" "$_ha_responses" \( -name '*.json' -o -name '*.tmp' \) \
    -mmin "+$((_ha_window / 60 + 1))" -delete 2>/dev/null; then
    warn "could not sweep stale harness-bridge state"
  fi

  _ha_id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  _ha_request="$_ha_requests/$_ha_id.json"
  _ha_response="$_ha_responses/$_ha_id.json"
  # WHY a temporary name beside the destination: the bridge plugin lists
  # requests with a glob, so a request must appear complete or not at all, and a
  # failed publish must still leave the caller a decision.
  _ha_request_tmp="$_ha_request.tmp"
  if ! jq -n \
    --arg id "$_ha_id" \
    --arg harness "$_ha_harness" \
    --arg tool "$_ha_tool" \
    --arg summary "$_ha_summary" \
    --argjson created_at "$(date +%s)" \
    '{id: $id, harness: $harness, tool: $tool, summary: $summary, created_at: $created_at}' \
    >"$_ha_request_tmp"; then
    rm -f "$_ha_request_tmp"
    warn "could not write the approval request"
    _ha_finish_error "could not write the approval request"
  fi
  if ! mv -f "$_ha_request_tmp" "$_ha_request"; then
    rm -f "$_ha_request_tmp"
    warn "could not publish the approval request"
    _ha_finish_error "could not publish the approval request"
  fi

  # WHY best-effort: the request file is the source of truth, so a failed
  # notification only means the user reads /harness status instead of being
  # pinged.
  if ! "$SCRIPT_DIR/send-notification.sh" "$_ha_harness" approval \
    "$_ha_tool: $_ha_summary (reply /harness approve $_ha_id)"; then
    warn "approval notification failed: the request is still visible via /harness status"
  fi
fi

# The prompt reads the terminal the hook runs under, never stdin: a hook's stdin
# is the harness payload, and a hook started without a terminal must answer
# `ask` rather than read its own EOF as a refusal.
_ha_prompt_live="$_ha_prompt"
_ha_tty=0
_ha_no_answer_reason="no approval source answered"
if [ "$_ha_prompt" -eq 1 ]; then
  if exec 3<>/dev/tty; then
    _ha_tty=1
  else
    warn "no terminal for the prompt source: answering ask"
    _ha_no_answer_reason="no terminal for the prompt source"
    _ha_prompt_live=0
  fi
fi

if [ "$_ha_tty" -eq 1 ]; then
  # WHY guarded like every other terminal write: a terminal that is opened and
  # then lost would otherwise end the run under `set -e` with no document at all,
  # which some harnesses read as a denial.
  if ! printf 'nucleus approval: %s: %s\n  run it? [y]es / [n]o / [a]llow once / [d]on'"'"'t: ' \
    "$_ha_tool" "$_ha_summary" >&3; then
    warn "could not write to the terminal: answering ask"
    _ha_no_answer_reason="could not write to the terminal"
    _ha_prompt_live=0
    _ha_tty=0
  fi
fi

_ha_answer=""
_ha_answer_reason=""
# Bytes already read but not yet a line: `read` saves partial input when it times
# out, and a terminal a TUI put in raw mode delivers a keystroke at a time, so an
# answer waits here for its line break instead of being thrown away.
_ha_line_buffer=""
_ha_hermes_live="$_ha_hermes"
_ha_now="$(date +%s)"
_ha_prompt_deadline=0
if [ "$_ha_timeout_prompt" -gt 0 ]; then
  _ha_prompt_deadline=$((_ha_now + _ha_timeout_prompt))
fi
_ha_hermes_deadline=0
if [ "$_ha_timeout_hermes" -gt 0 ]; then
  _ha_hermes_deadline=$((_ha_now + _ha_timeout_hermes))
fi

# One loop races the sources: the response file is checked every pass, and a
# live prompt reads the terminal with a one-second timeout that doubles as the
# poll interval. The first answer wins, and the other source is dropped by
# leaving the loop, which is why neither side needs a killer process.
while [ -z "$_ha_answer" ]; do
  _ha_now="$(date +%s)"

  if [ "$_ha_hermes_live" -eq 1 ] && [ -f "$_ha_response" ]; then
    _ha_hermes_live=0
    if ! _ha_response_doc="$(jq -c 'if type == "object" then . else empty end' "$_ha_response" 2>/dev/null)"; then
      _ha_response_doc=""
    fi
    # check-suppress:suppression_doc: jq fails on a malformed or non-JSON Hermes response; the empty decision is intentionally converted into the typed resolver-error decision below, not a silent fallback.
    _ha_answer="$(jq -r '.decision // empty' <<<"$_ha_response_doc" 2>/dev/null || true)"
    case "$_ha_answer" in
    allow | deny)
      _ha_answer_reason="$(jq -r 'if (.reason | type) == "string" and (.reason | length) > 0 then .reason else "hermes decision" end' <<<"$_ha_response_doc")"
      _ha_decided_by="hermes"
      break
      ;;
    *)
      warn "malformed hermes approval response: answering deny"
      # WHY break instead of finishing here: the request and response are
      # removed after the loop, and that cleanup must also run on this error.
      _ha_answer="deny"
      _ha_answer_reason="malformed hermes approval response"
      _ha_decided_by="resolver-error"
      break
      ;;
    esac
  fi

  if [ "$_ha_prompt_live" -eq 1 ] && [ "$_ha_prompt_deadline" -ne 0 ] &&
    [ "$_ha_now" -ge "$_ha_prompt_deadline" ]; then
    _ha_mark_timeout prompt
    _ha_prompt_live=0
  fi
  if [ "$_ha_hermes_live" -eq 1 ] && [ "$_ha_hermes_deadline" -ne 0 ] &&
    [ "$_ha_now" -ge "$_ha_hermes_deadline" ]; then
    _ha_mark_timeout hermes
    _ha_hermes_live=0
  fi
  if [ "$_ha_prompt_live" -eq 0 ] && [ "$_ha_hermes_live" -eq 0 ]; then
    break
  fi

  if [ "$_ha_prompt_live" -eq 1 ]; then
    _ha_chunk=""
    if IFS= read -r -s -t 1 _ha_chunk <&3; then
      _ha_rc=0
    else
      _ha_rc=$?
    fi
    # WHY the chunk is kept either way: a timeout above 128 still carries what was
    # typed, and dropping it is invisible in canonical mode, where the kernel holds
    # the bytes, but loses the answer outright in raw mode, where every read takes
    # them. The prompt shares the terminal with the harness, so a keystroke meant
    # for its TUI must not answer for the operator: a decision still needs a line.
    _ha_line_buffer="$_ha_line_buffer$_ha_chunk"
    # WHY two ways to complete: a read that succeeds stopped at the LF and did not
    # keep it, while a raw-mode Enter is a bare CR that `read` does not treat as
    # end of line and leaves inside the partial input a timeout saves.
    _ha_complete=0
    if [ "$_ha_rc" -eq 0 ]; then
      _ha_complete=1
    else
      case "$_ha_line_buffer" in
      *$'\r'* | *$'\n'*) _ha_complete=1 ;;
      esac
    fi
    if [ "$_ha_complete" -eq 1 ]; then
      _ha_line="${_ha_line_buffer%%[[:cntrl:]]*}"
      _ha_line_buffer=""
      # The prompt reads `[y]es`, so the spelled-out word is an answer as well,
      # and the comparison ignores case and spaces because the line is what the
      # operator typed rather than what any terminal normalized.
      _ha_word="${_ha_line,,}"
      _ha_word="${_ha_word//[[:space:]]/}"
      case "$_ha_word" in
      a | allow | y | yes)
        _ha_answer="allow"
        _ha_answer_reason="prompt allowed"
        _ha_decided_by="prompt"
        ;;
      d | "don't" | dont | n | no)
        _ha_answer="deny"
        _ha_answer_reason="prompt denied"
        _ha_decided_by="prompt"
        ;;
      # An empty line, or any other word, is not an answer: the prompt stays live
      # and the next pass reads again, which is what a stray Enter or a correction
      # should do.
      *) ;;
      esac
    fi
    # WHY end of input stops the source: `read` reports a timeout above 128 and
    # end of input or a closed terminal at or below it, and the status cannot
    # separate an EOF from a read error, so nobody can answer from that terminal
    # any more and waiting out the timeout would only delay the harness's prompt.
    if [ "$_ha_rc" -ne 0 ] && [ "$_ha_rc" -le 128 ]; then
      warn "the terminal is at end of input or closed before an answer: answering ask"
      _ha_no_answer_reason="the terminal closed before an answer"
      _ha_prompt_live=0
    fi
  else
    sleep 1
  fi
done

if [ "$_ha_tty" -eq 1 ]; then
  # A prompt answered by Hermes leaves the question on screen, so the line is
  # closed before the terminal is handed back to the harness.
  if ! printf '\n' >&3; then
    warn "could not write to the terminal"
  fi
  if ! exec 3<&-; then
    warn "could not close the terminal"
  fi
fi

if [ "$_ha_hermes" -eq 1 ]; then
  # WHY consume either way: an answered request would otherwise stay in
  # `/harness status`, and an unanswered one must not linger as pending.
  rm -f "$_ha_request" "$_ha_response"
fi

if jq -e 'index("hermes") != null and index("prompt") != null' <<<"$_ha_timed_out" >/dev/null 2>&1; then
  _ha_finish deny "all approval sources timed out (hermes 300s, prompt 600s)" all-timeouts
fi
_ha_finish "${_ha_answer:-ask}" "${_ha_answer_reason:-$_ha_no_answer_reason}" "${_ha_decided_by:-none}"
