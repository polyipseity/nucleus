#!/usr/bin/env bash
# Requests a remote approval decision for a harness tool call.
#
# A blocking harness hook (Cursor beforeShellExecution, VS Code Copilot
# PreToolUse, pi tool_call, opencode permission) calls this, then maps the
# printed decision onto its own response shape.  The request appears on every
# configured Hermes channel and is answered with `/harness approve <id>` or
# `/harness deny <id>`; `/harness status` lists what is still outstanding.
#
# Usage:
#   harness-approval <harness> <tool> <summary> [timeout-seconds]
#       Prints exactly one of: allow | deny | ask
#   harness-approval hook <harness>
#       Reads the harness hook payload (JSON) on stdin and prints that
#       harness's native decision document, so one deployed command can be
#       referenced from a shared hook definition on every platform:
#         cursor  -> {"permission":"allow"|"ask"|"deny"}
#         copilot -> {"hookSpecificOutput":{...,"permissionDecision":"…"}}
#         others  -> plain allow | deny | ask
#
# `ask` means "no remote decision" — the harness must fall back to its own local
# prompt.  Every path prints a decision and exits 0: a harness hook that fails is
# treated as a denial by some harnesses, which would turn a broker outage into a
# blocked session.
#
# Config (~/.local/state/nucleus/config.json):
#   harness-notify.enable    boolean, default true; false disables remote
#                            approvals entirely (every call answers `ask`)
#   harness-approval.timeout-seconds  integer, default 120
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
    # WHY: the two hook payloads nucleus wires (Cursor beforeShellExecution,
    # Copilot PreToolUse) are JSON objects, but a harness may also hand over
    # plain text.  jq failing means "not one of the known shapes", so the raw
    # payload is carried through as the summary instead of dropping it.
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
  # A hook payload is multi-line JSON; the request description is one line.
  _ha_summary="${_ha_summary//$'\n'/ }"
  _ha_summary="${_ha_summary:0:200}"
else
  _ha_harness="${1-}"
  _ha_tool="${2-}"
  _ha_summary="${3-}"
  _ha_timeout_arg="${4-}"
fi

# Renders the decision in the calling harness's own vocabulary.  `ask` is a
# valid value in every shape, so the neutral answer is always expressible.
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
# asked and how it was answered has to be recoverable), rendered in the calling
# harness's vocabulary, and the process exits 0.
_ha_finish() {
  case "${1-}" in
  allow | deny) _ha_decision="$1" ;;
  *) _ha_decision="ask" ;;
  esac
  _ha_log_dir="$_ha_root/logs"
  mkdir -p "$_ha_log_dir"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha_harness" "$_ha_tool" "$_ha_decision" "$_ha_summary" \
    >>"$_ha_log_dir/harness-bridge.log"
  _ha_render "$_ha_decision"
  exit 0
}

if [ -z "$_ha_harness" ]; then
  _ha_usage
  printf 'ask\n'
  exit 0
fi

# The hook form is the only one allowed to omit the action description; the
# plain form is called by pi with every argument.
if [ -z "$_ha_tool" ]; then
  _ha_usage
  _ha_finish ask
fi

_ha_defaults='{"harness-notify":{"enable":true},"harness-approval":{"timeout-seconds":120}}'
_ha_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  _ha_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"
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

_ha_timeout="${_ha_timeout_arg:-$(jq -r '."harness-approval"."timeout-seconds"' <<<"$_ha_config")}"

_ha_dir="$_ha_root/state/harness-bridge"
_ha_requests="$_ha_dir/requests"
_ha_responses="$_ha_dir/responses"
mkdir -p "$_ha_requests" "$_ha_responses"

# A harness killed mid-poll leaves its request behind; such an entry can never
# be answered and would otherwise stay in `/harness status` forever.  The
# generous factor keeps a slow-but-live approval untouched.
_ha_stale_after=$((_ha_timeout * 4))
# Best-effort: a failed sweep must not block the approval — the request file for
# this call is still written, and /harness status stays correct for new entries.
if ! find "$_ha_requests" "$_ha_responses" -name '*.json' \
  -mmin "+$((_ha_stale_after / 60 + 1))" -delete 2>/dev/null; then
  warn "could not sweep stale harness-bridge state"
fi

_ha_id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
_ha_request="$_ha_requests/$_ha_id.json"
jq -n \
  --arg id "$_ha_id" \
  --arg harness "$_ha_harness" \
  --arg tool "$_ha_tool" \
  --arg summary "$_ha_summary" \
  --argjson created_at "$(date +%s)" \
  '{id: $id, harness: $harness, tool: $tool, summary: $summary, created_at: $created_at}' \
  >"$_ha_request"

# Best-effort: the request file is the source of truth, so a failed notification
# only means the user has to look at /harness status instead of being pinged.
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

# The request is consumed either way: an answered request would otherwise stay in
# `/harness status`, and an unanswered one must not linger as pending forever.
rm -f "$_ha_request" "$_ha_response"

_ha_finish "$_ha_decision"
