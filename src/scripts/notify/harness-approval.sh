#!/usr/bin/env bash
# Requests a remote approval decision for a harness tool call.
#
# A blocking harness hook (Cursor beforeShellExecution, VS Code Copilot
# PreToolUse, pi tool_call, opencode permission) calls this and maps the printed
# decision onto its own response shape. The request appears on every configured
# Hermes channel, answered with `/harness approve <id>` or `/harness deny <id>`.
#
#   harness-approval <harness> <tool> <summary> [timeout-seconds]
#       Prints exactly one of: allow | deny | ask
#   harness-approval hook <harness>
#       Reads the JSON hook payload on stdin and prints that harness's native
#       decision document, so one command serves a shared hook definition:
#         cursor  -> {"permission":"allow"|"ask"|"deny"}
#         copilot -> {"hookSpecificOutput":{...,"permissionDecision":"…"}}
#         others  -> plain allow | deny | ask
#
# `ask` means "no remote decision" and the harness falls back to its own local
# prompt. Every path prints a decision and exits 0, because some harnesses treat
# a failed hook as a denial, which would turn a broker outage into a blocked
# session.
#
# ~/.local/state/nucleus/config.json: harness-notify.enable (default true, false
# disables the whole bridge and answers `ask`), harness-approval.enable (default
# false, false answers `ask` at once with no request, notification, or wait), and
# harness-approval.timeout-seconds (default 120).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_ha_usage() {
  warn "usage: harness-approval <harness> <tool> <summary> [timeout-seconds]"
  warn "       harness-approval hook <harness>   # hook payload on stdin"
}

_ha_harness=""
_ha_tool=""
_ha_summary=""
_ha_timeout_arg=""

if [ "${1-}" = "hook" ]; then
  _ha_harness="${2-}"
  if [ ! -t 0 ]; then
    _ha_payload="$(cat)"
  else
    _ha_payload=""
  fi
  case "$_ha_payload" in
  \{*)
    # WHY: a harness may hand over plain text instead of JSON, and jq failing
    # means "not a known shape", so the raw payload becomes the summary rather
    # than being dropped.
    if ! _ha_tool="$(jq -r '.tool_name // .tool // .hook_event_name // "hook"' <<<"$_ha_payload" 2>&1)"; then
      _ha_tool="hook"
    fi
    if ! _ha_summary="$(jq -rc '.tool_input // .command // .arguments // .' <<<"$_ha_payload" 2>&1)"; then
      _ha_summary="$_ha_payload"
    fi
    ;;
  "") _ha_tool="hook" ;;
  *)
    _ha_tool="hook"
    _ha_summary="$_ha_payload"
    ;;
  esac
  # A hook payload is multi-line JSON, the request description is one line.
  _ha_summary="${_ha_summary//$'\n'/ }"
  _ha_summary="${_ha_summary:0:200}"
else
  _ha_harness="${1-}"
  _ha_tool="${2-}"
  _ha_summary="${3-}"
  _ha_timeout_arg="${4-}"
fi

# WHY: `ask` is a valid value in every shape, so the neutral answer is always
# expressible.
_ha_render() {
  case "$_ha_harness" in
  cursor) printf '{"permission":"%s"}\n' "$1" ;;
  copilot)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"nucleus harness-approval"}}\n' "$1"
    ;;
  *) printf '%s\n' "$1" ;;
  esac
}

_ha_root="$(derive_nucleus_user_root)"

# Every path ends here: the decision is logged (hooks run invisibly, so what was
# asked and how it was answered has to be recoverable) and the process exits 0.
_ha_finish() {
  case "${1-}" in
  allow | deny) _ha_decision="$1" ;;
  *) _ha_decision="ask" ;;
  esac
  _ha_log_dir="$_ha_root/logs"
  # WHY best-effort: the decision is already made, and a hook that prints
  # nothing reads as a denial in Copilot, so an unwritable log dir must not
  # swallow the answer.
  if ! { mkdir -p "$_ha_log_dir" &&
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha_harness" "$_ha_tool" "$_ha_decision" "$_ha_summary" \
      >>"$_ha_log_dir/harness-bridge.log"; }; then
    warn "could not write the harness-bridge audit log"
  fi
  _ha_render "$_ha_decision"
  exit 0
}

if [ -z "$_ha_harness" ]; then
  _ha_usage
  printf 'ask\n'
  exit 0
fi

# Only the hook form may omit the action description; pi calls the plain form
# with every argument.
if [ -z "$_ha_tool" ]; then
  _ha_usage
  _ha_finish ask
fi

_ha_defaults='{"harness-notify":{"enable":true},"harness-approval":{"enable":false,"timeout-seconds":120}}'
_ha_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  # WHY: an unreadable config takes the unparsable exit with its message, since
  # a hook dying under `set -e` prints no decision and Copilot reads that as a
  # denial.
  if ! _ha_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"; then
    warn "could not parse nucleus config — asking locally"
    _ha_finish ask
  fi
fi
if ! _ha_config="$(
  jq -c --argjson defaults "$_ha_defaults" --argjson user "$_ha_user_config" \
    '$defaults * { "harness-notify": ($user["harness-notify"] // {}), "harness-approval": ($user["harness-approval"] // {}) }' <<<'{}'
)"; then
  warn "could not parse nucleus config — asking locally"
  _ha_finish ask
fi

if [ "$(jq -r '."harness-notify".enable' <<<"$_ha_config")" != "true" ]; then
  _ha_finish ask
fi

# WHY: the remote gate is off by default, so the hooks stay wired (a flag flip
# re-enables them) while every tool call is answered `ask` and the harness keeps
# its own prompt.
if [ "$(jq -r '."harness-approval".enable' <<<"$_ha_config")" != "true" ]; then
  _ha_finish ask
fi

_ha_timeout="${_ha_timeout_arg:-$(jq -r '."harness-approval"."timeout-seconds"' <<<"$_ha_config")}"

_ha_dir="$_ha_root/state/harness-bridge"
_ha_requests="$_ha_dir/requests"
_ha_responses="$_ha_dir/responses"
# WHY: the state tree is the first thing created under the USER root, so an
# unwritable root fails here. Answering `ask` keeps the harness's own prompt
# instead of letting `set -e` end the run without a document.
if ! mkdir -p "$_ha_requests" "$_ha_responses"; then
  warn "could not create the harness-bridge state directory"
  _ha_finish ask
fi

# WHY: a harness killed mid-poll leaves a request that can never be answered, and
# an interrupted publish leaves a .tmp companion; both would otherwise stay in
# `/harness status` forever. The generous factor keeps a slow-but-live approval.
_ha_stale_after=$((_ha_timeout * 4))
# WHY best-effort: this call's request file is still written and /harness status
# stays correct for new entries.
if ! find "$_ha_requests" "$_ha_responses" \( -name '*.json' -o -name '*.tmp' \) \
  -mmin "+$((_ha_stale_after / 60 + 1))" -delete 2>/dev/null; then
  warn "could not sweep stale harness-bridge state"
fi

_ha_id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
_ha_request="$_ha_requests/$_ha_id.json"
# WHY a temporary name beside the destination: the bridge plugin lists requests
# with a glob, so a request must appear complete or not at all, and a failed
# publish must still leave the caller a decision.
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
  _ha_finish ask
fi
if ! mv -f "$_ha_request_tmp" "$_ha_request"; then
  rm -f "$_ha_request_tmp"
  warn "could not publish the approval request"
  _ha_finish ask
fi

# WHY best-effort: the request file is the source of truth, so a failed
# notification only means the user reads /harness status instead of being pinged.
if ! "$SCRIPT_DIR/harness-notify.sh" "$_ha_harness" approval \
  "$_ha_tool: $_ha_summary (reply /harness approve $_ha_id)"; then
  warn "approval notification failed — the request is still visible via /harness status"
fi

_ha_response="$_ha_responses/$_ha_id.json"
_ha_waited=0
_ha_decision=""
while [ "$_ha_waited" -lt "$_ha_timeout" ]; do
  if [ -f "$_ha_response" ]; then
    _ha_decision="$(jq -r '.decision // empty' "$_ha_response")"
    break
  fi
  sleep 2
  _ha_waited=$((_ha_waited + 2))
done

# WHY consume either way: an answered request would otherwise stay in
# `/harness status`, and an unanswered one must not linger as pending.
rm -f "$_ha_request" "$_ha_response"

_ha_finish "$_ha_decision"
