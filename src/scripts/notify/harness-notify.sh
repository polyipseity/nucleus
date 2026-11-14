#!/usr/bin/env bash
# Normalizes a coding-harness lifecycle event into a Hermes notification.
# Every harness (pi, opencode, Cursor, VS Code Copilot Chat) funnels its hook
# payload through here so formatting, channel selection and failure handling have
# one definition.
#
# Delivery goes through `hermes send`, which reuses the credentials and channel
# config the gateway already owns (~/.hermes/.env, ~/.hermes/config.yaml). nucleus
# stores no bot tokens of its own and needs no running gateway.
#
# Usage: harness-notify <harness> <event> [text]
#   harness  pi | opencode | cursor | copilot
#   event    done | needs-input | approval | error
#   text     Optional body. When omitted, stdin is read: raw text, or a hook
#            JSON object from which a message field is extracted.
#
# Always exits 0. A hook runner in some harnesses reads a non-zero exit as a
# denial, so a failed notification must never block the harness that emitted it.
#
# Config (~/.local/state/nucleus/config.json, `nucleus-config`):
#   harness-notify.enable    boolean, default true
#   harness-notify.channels  hermes send targets, default
#                            ["telegram", "ntfy", "discord"]; a channel the host
#                            has not set up fails delivery and warns
#   harness-notify.max-chars integer body cap, default 1200
#
# The other two gates live in their own entry points: `harness-approval.sources`
# (default ["prompt"]) answers tool calls, `harness-drive.enable` (default true)
# decides whether a queued prompt is injected after a finished turn.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# WHY the shared library, not a log path: nucleus-logs owns the log root, the
# line format, and the append, so every notification lands where the gate's own
# decisions do.
# shellcheck source=../lib/logs.sh
. "$SCRIPT_DIR/../lib/logs.sh"
# shellcheck source=../lib/harness-audit.sh
. "$SCRIPT_DIR/../lib/harness-audit.sh"

_hn_start="$(harness_audit_now_ms)"

# _hn_audit <summary>: record this notification attempt.
# WHY best-effort: a notification is advisory, so a failed append warns and the
# delivery result stands.
_hn_audit() {
  if ! (
    _hn_audit_digest="$(printf '%s' "${_hn_stdin-}" | harness_audit_digest)" || exit 1
    _hn_audit_summary="$(printf '%s\n' "$1" | harness_audit_summary)"
    harness_audit_log notify "$_hn_harness" '' none '' '' \
      "$(($(harness_audit_now_ms) - _hn_start))" \
      "$_hn_audit_summary" "$_hn_audit_digest" ''
  ); then
    warn "could not write the harness audit log"
  fi
}

_hn_harness="${1-}"
_hn_event="${2-}"
_hn_text="${3-}"

if [ -z "$_hn_harness" ] || [ -z "$_hn_event" ]; then
  warn "usage: harness-notify <harness> <event> [text]"
  exit 0
fi

case "$_hn_event" in
done | needs-input | approval | error) ;;
*)
  warn "unknown event '$_hn_event': not notifying"
  exit 0
  ;;
esac

# WHY: defaults are mirrored from scripts/config.sh DEFAULTS, the SSOT for
#   runtime toggles. Reading the file directly keeps this path usable from
#   harness hooks, which run outside any nucleus activation context.
_hn_defaults='{"enable":true,"channels":["telegram","ntfy","discord"],"max-chars":1200}'
_hn_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  # WHY: an unreadable config takes the unparsable exit, message included, so
  #   both platforms report one string per action and `set -e` cannot kill a
  #   hook before it writes anything.
  if ! _hn_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"; then
    warn "could not parse nucleus config: not notifying"
    exit 0
  fi
fi
_hn_config="$(
  jq -c --argjson defaults "$_hn_defaults" --argjson user "$_hn_user_config" \
    '$defaults * ($user["harness-notify"] // {})' <<<'{}'
)" || {
  warn "could not parse nucleus config: not notifying"
  exit 0
}

if [ "$(jq -r '.enable' <<<"$_hn_config")" != "true" ]; then
  exit 0
fi

_hn_max_chars="$(jq -r '."max-chars"' <<<"$_hn_config")"

# Body: explicit argument wins, otherwise stdin (raw text or hook JSON).
if [ -z "$_hn_text" ] && [ ! -t 0 ]; then
  _hn_stdin="$(cat)"
  case "$_hn_stdin" in
  \{*)
    # A malformed payload is not an error: fall back to the raw text.
    if ! _hn_text="$(jq -r '.message // .prompt // .text // .tool_name // ""' <<<"$_hn_stdin" 2>/dev/null)"; then
      _hn_text="$_hn_stdin"
    fi
    ;;
  *)
    _hn_text="$_hn_stdin"
    ;;
  esac
fi

case "$_hn_event" in
done) _hn_label="finished" ;;
needs-input) _hn_label="needs input" ;;
approval) _hn_label="approval needed" ;;
error) _hn_label="error" ;;
esac

if [ -z "${_hn_text//[[:space:]]/}" ]; then
  _hn_text="$_hn_label"
fi
_hn_text="${_hn_text:0:_hn_max_chars}"

_hn_hermes=""
if command -v hermes >/dev/null; then
  _hn_hermes="$(command -v hermes)"
fi

if [ -z "$_hn_hermes" ]; then
  warn "hermes is not on PATH: notification dropped"
  _hn_audit "$_hn_label: notification dropped (hermes is not on PATH)"
  exit 0
fi

_hn_subject="[$_hn_harness] $_hn_label"
while IFS= read -r _hn_target; do
  [ -n "$_hn_target" ] || continue
  if ! printf '%s\n' "$_hn_text" |
    "$_hn_hermes" send --to "$_hn_target" --subject "$_hn_subject" --file - --quiet; then
    warn "delivery to '$_hn_target' failed"
  fi
done < <(jq -r '.channels[]' <<<"$_hn_config")

_hn_audit "$_hn_label: $_hn_text"

exit 0
