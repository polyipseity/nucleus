#!/usr/bin/env bash
# Normalizes a coding-harness lifecycle event into a Hermes notification.
#
# Every provisioned harness (pi, opencode, Cursor, VS Code Copilot Chat, Copilot
# CLI) funnels its hook payload through this single entry point so message
# formatting, channel selection and failure handling have one definition.
#
# Delivery goes through `hermes send`, which reuses the platform credentials and
# channel configuration the Hermes gateway already owns (~/.hermes/.env and
# ~/.hermes/config.yaml).  nucleus therefore stores no bot tokens of its own for
# notifications, and no gateway process needs to be running for bot-token
# platforms.
#
# Usage: harness-notify <harness> <event> [text]
#   harness  pi | opencode | cursor | copilot | copilot-cli | vscode
#   event    done | needs-input | approval | error
#   text     Optional body.  When omitted, stdin is read: raw text, or a hook
#            JSON object from which a message field is extracted.
#
# Exit status is always 0.  A notification is best-effort; it must never block or
# fail the harness that emitted it, and hook runners treat a non-zero exit as a
# denial in some harnesses.
#
# Config (~/.local/state/nucleus/config.json, `nucleus-config`):
#   harness-notify.enable    boolean, default true
#   harness-notify.channels  array of `hermes send` targets, default ["telegram"]
#   harness-notify.max-chars integer body cap, default 1200
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_hn_harness="${1-}"
_hn_event="${2-}"
_hn_text="${3-}"

if [ -z "$_hn_harness" ] || [ -z "$_hn_event" ]; then
  error "usage: harness-notify <harness> <event> [text]"
  exit 0
fi

case "$_hn_event" in
done | needs-input | approval | error) ;;
*)
  warn "unknown event '$_hn_event' — not notifying"
  exit 0
  ;;
esac

# WHY: defaults are mirrored from scripts/config.sh DEFAULTS (the SSOT for
# runtime toggles).  Reading the file directly keeps this path usable from
# harness hooks, which run outside any nucleus activation context.
_hn_defaults='{"enable":true,"channels":["telegram"],"max-chars":1200}'
_hn_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  _hn_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"
fi
_hn_config="$(
  jq -c --argjson defaults "$_hn_defaults" --argjson user "$_hn_user_config" \
    '$defaults * ($user["harness-notify"] // {})' <<<'{}'
)" || {
  warn "could not parse nucleus config — not notifying"
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
    # A malformed payload is not an error here: fall back to the raw text.
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
  warn "hermes is not on PATH — notification dropped"
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

exit 0
