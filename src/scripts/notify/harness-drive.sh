#!/usr/bin/env bash
# Ends a harness turn: notify, then inject one queued remote prompt.
#
# Every "the agent stopped" hook calls this instead of `harness-notify`, because
# the same moment is when a prompt queued with `/harness send <harness> <text>`
# can be delivered.  The hook payload on stdin is forwarded verbatim to
# `harness-notify.sh <harness> done`, so the notification half has one definition.
#
# Usage: harness-drive <harness>
#   harness  pi | opencode | cursor | copilot
#   stdin    the harness stop-hook payload, if any (JSON)
#
# Continuation document (stdout) — exactly one queued prompt is consumed:
#   cursor   {"followup_message":"<text>"}                       (Cursor native)
#   copilot  {"hookSpecificOutput":{"hookEventName":"Stop",
#             "decision":"block","reason":"<text>"}}             (VS Code native)
#   others   no output (pi and opencode are driven through their own APIs)
# With nothing queued, cursor and copilot receive {} and the others nothing.
#
# One prompt per turn, consumed before it is printed: the queue is the only
# loop guard, so a command file can never be delivered twice.
#
# Cursor ignores `followup_message` on Windows (forum.cursor.com/t/155078: valid
# JSON, exit 0, agent does not continue), so remote driving of Cursor sessions
# works on macOS and NixOS only.  Nothing here compensates for that: a
# workaround would have to fake user input into the harness.
#
# Exit status is always 0: a stop hook that fails is surfaced as a failed turn,
# and no part of this path may block the harness.
#
# Config (~/.local/state/nucleus/config.json):
#   harness-notify.enable  boolean, default true; false disables the whole bridge,
#                          so nothing is notified and nothing is drained.
#   harness-drive.enable   boolean, default true; false keeps the completion
#                          notification but never injects a queued prompt.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_hd_harness="${1-}"

if [ -z "$_hd_harness" ]; then
  warn "usage: harness-drive <harness>"
  exit 0
fi

# Nothing is rendered for harnesses without a stop-hook continuation document.
_hd_empty() {
  case "$1" in
  cursor | copilot) printf '{}\n' ;;
  *) ;;
  esac
}

# Renders the continuation in the calling harness's own vocabulary.  Encoding is
# always done by jq: a hand-built JSON document would break on the first quote,
# backslash or newline in a prompt.
_hd_render() { # <harness> <text>
  case "$1" in
  cursor)
    if ! jq -cn --arg msg "$2" '{followup_message: $msg}'; then
      warn "could not encode the Cursor continuation"
      printf '{}\n'
    fi
    ;;
  copilot)
    if ! jq -cn --arg reason "$2" \
      '{hookSpecificOutput: {hookEventName: "Stop", decision: "block", reason: $reason}}'; then
      warn "could not encode the Copilot continuation"
      printf '{}\n'
    fi
    ;;
  *) ;;
  esac
}

_hd_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  _hd_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"
fi
if ! _hd_config="$(
  jq -c --argjson defaults '{"harness-notify":{"enable":true},"harness-drive":{"enable":true}}' --argjson user "$_hd_user_config" \
    '$defaults * { "harness-notify": ($user["harness-notify"] // {}), "harness-drive": ($user["harness-drive"] // {}) }' <<<'{}'
)"; then
  warn "could not parse nucleus config — not driving"
  _hd_empty "$_hd_harness"
  exit 0
fi

if [ "$(jq -r '."harness-notify".enable' <<<"$_hd_config")" != "true" ]; then
  _hd_empty "$_hd_harness"
  exit 0
fi

if [ -t 0 ]; then
  _hd_payload=""
else
  _hd_payload="$(cat)"
fi

# The notification half shares one implementation; an empty payload still means
# "the turn finished", which is what harness-notify turns into its default body.
if ! printf '%s' "$_hd_payload" | "$SCRIPT_DIR/harness-notify.sh" "$_hd_harness" "done"; then
  warn "notification failed — continuing to the queued prompt"
fi

_hd_commands="$(derive_nucleus_user_root)/state/harness-bridge/commands/$_hd_harness"

# Driving has its own gate, and it is checked after the notification: with
# driving off the turn is still announced, it just never continues.
if [ "$(jq -r '."harness-drive".enable' <<<"$_hd_config")" != "true" ]; then
  # WHY: a prompt queued while driving is off can never be delivered, and
  # delivering it hours later (after the flag is flipped back) would be worse
  # than dropping it, so it is discarded here and recorded in the audit log.
  _hd_dropped=0
  if [ -d "$_hd_commands" ]; then
    for _hd_file in "$_hd_commands"/*.json; do
      [ -f "$_hd_file" ] || continue
      if ! rm -f "$_hd_file"; then
        warn "could not discard the queued prompt '$_hd_file'"
        continue
      fi
      _hd_dropped=$((_hd_dropped + 1))
    done
  fi
  if [ "$_hd_dropped" -gt 0 ]; then
    _hd_log_dir="$(derive_nucleus_user_root)/logs"
    mkdir -p "$_hd_log_dir"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_hd_harness" "drive" "disabled" \
      "dropped $_hd_dropped queued prompt(s)" \
      >>"$_hd_log_dir/harness-bridge.log"
    warn "harness-drive is disabled — dropped $_hd_dropped queued prompt(s)"
  fi
  _hd_empty "$_hd_harness"
  exit 0
fi

# Newest by file name: the plugin names each entry "<epoch>-<id>.json", so a
# lexicographic maximum is the most recently queued prompt.
_hd_newest=""
if [ -d "$_hd_commands" ]; then
  for _hd_file in "$_hd_commands"/*.json; do
    [ -f "$_hd_file" ] || continue
    if [ -z "$_hd_newest" ] || [[ "$_hd_file" > "$_hd_newest" ]]; then
      _hd_newest="$_hd_file"
    fi
  done
fi

if [ -z "$_hd_newest" ]; then
  _hd_empty "$_hd_harness"
  exit 0
fi

if ! _hd_text="$(jq -r '.text // empty' "$_hd_newest")"; then
  warn "could not read the queued prompt '$_hd_newest' — treating it as empty"
  _hd_text=""
fi

if [ -z "${_hd_text//[[:space:]]/}" ]; then
  warn "queued prompt is empty — nothing to inject"
  if ! rm -f "$_hd_newest"; then
    warn "could not discard the empty queued prompt"
  fi
  _hd_empty "$_hd_harness"
  exit 0
fi

# Consume before printing: if the delete fails, delivering the prompt anyway
# would let the next turn deliver it again, so the prompt is dropped instead.
if ! rm -f "$_hd_newest"; then
  warn "could not consume the queued prompt — dropping it to avoid double delivery"
  _hd_empty "$_hd_harness"
  exit 0
fi

_hd_render "$_hd_harness" "$_hd_text"
exit 0
