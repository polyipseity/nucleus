#!/usr/bin/env bash
# Requests a remote approval decision for a harness tool call.
#
# A blocking harness hook (Cursor beforeShellExecution, pi tool_call, …) calls
# this with the pending action, then maps the printed decision onto its own
# response shape. The request appears on every configured Hermes channel and is
# answered with `/harness approve <id>` or `/harness deny <id>`; the same
# `/harness status` view lists what is still outstanding.
#
# Usage: harness-approval <harness> <tool> <summary> [timeout-seconds]
#   Prints exactly one of: allow | deny | ask
#
# `ask` means "no remote decision" — the harness must fall back to its own local
# prompt. Every path prints a decision and exits 0: a harness hook that fails is
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

_ha_harness="${1-}"
_ha_tool="${2-}"
_ha_summary="${3-}"
_ha_timeout_arg="${4-}"

if [ -z "$_ha_harness" ] || [ -z "$_ha_tool" ]; then
  warn "usage: harness-approval <harness> <tool> <summary> [timeout-seconds]"
  printf 'ask\n'
  exit 0
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
  printf 'ask\n'
  exit 0
fi

if [ "$(jq -r '."harness-notify".enable' <<<"$_ha_config")" != "true" ]; then
  printf 'ask\n'
  exit 0
fi

_ha_timeout="${_ha_timeout_arg:-$(jq -r '."harness-approval"."timeout-seconds"' <<<"$_ha_config")}"

_ha_dir="$(derive_nucleus_user_root)/state/harness-bridge"
_ha_requests="$_ha_dir/requests"
_ha_responses="$_ha_dir/responses"
mkdir -p "$_ha_requests" "$_ha_responses"

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

case "$_ha_decision" in
allow) printf 'allow\n' ;;
deny) printf 'deny\n' ;;
*)
  printf 'ask\n'
  ;;
esac
exit 0
