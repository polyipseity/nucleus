#!/usr/bin/env bash
# Turns a harness hook payload into that harness's native decision document by
# running the filters declared in the registry.
#
#   harness-filter <harness>
#       Reads the JSON hook payload on stdin and prints exactly one document, so
#       one command serves every harness's hook definition:
#         cursor           -> {"permission":"allow"|"ask"|"deny"}
#         claude, copilot  -> {"hookSpecificOutput":{...,"permissionDecision":"…"}}
#         pi, opencode,
#         codex, others    -> plain allow | deny | ask
#
# The registry is `src/modules/configs/harness-filters.json`, read from the live
# checkout through derive_repo_root (method 4: runtime direct read) because the
# file is data, not a script, and so never reaches the script-tree bundle.
#
# Filter protocol (one process per enabled registry entry, in registry order):
#   filters/<id>.sh --settings <json> --command <text>
#   stdin  the raw hook payload, for a filter that needs more than the command
#   stdout exactly one line: decision<TAB>rule<TAB>reason
#   decision is allow, ask, or deny; a non-zero exit, a missing script, or a line
#   that does not carry three tab-separated fields is recorded as ask with rule
#   `filter-error`, because the filter could not state a verdict.
#
# The decisions aggregate as deny > ask > allow regardless of registry order, so
# registry order stays readable instead of load-bearing. `ask` means "no decision
# here" and the harness falls back to its own local prompt.
#
# Every path prints a document and exits 0, because several harnesses read a
# failed hook as a denial, which would turn a broken registry into a blocked
# session.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_hf_harness="${1-}"
_hf_payload=""
if [ ! -t 0 ]; then
  _hf_payload="$(cat)"
fi

# Renders the decision in the calling harness's own vocabulary. `ask` is a valid
# value in every shape, so the neutral answer is always expressible. The two
# document shapes are the ones the harnesses parse today (Copilot PreToolUse,
# Cursor beforeShellExecution); the plain word is what pi and opencode read from
# the last stdout line, and what a harness without a document shape ignores.
_hf_render() { # <decision> <reason>
  case "$_hf_harness" in
  cursor) jq -cn --arg d "$1" '{permission: $d}' ;;
  claude | copilot)
    jq -cn --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
    ;;
  *) printf '%s\n' "$1" ;;
  esac
}

# Every path ends here.
_hf_finish() { # <decision> <reason>
  case "${1-}" in
  allow | deny) _hf_decision="$1" ;;
  *) _hf_decision="ask" ;;
  esac
  _hf_render "$_hf_decision" "${2-}"
  exit 0
}

_hf_rank() { # <decision>
  case "$1" in
  deny) printf '3' ;;
  ask) printf '2' ;;
  *) printf '1' ;;
  esac
}

_hf_repo_root=""
if ! _hf_repo_root="$(derive_repo_root)"; then
  warn "could not resolve the repository root: asking locally"
  _hf_finish ask "harness-filter (registry-error): the repository root is unknown, so the filter registry cannot be read"
fi
# check-suppress:config-method: method 4 (runtime direct read) -- the registry is data the runner reads from the live checkout, so a writable symlink into the store or the home directory would freeze the filter list until the next apply
_hf_registry="$_hf_repo_root/src/modules/configs/harness-filters.json"

_hf_entries=""
if [ ! -f "$_hf_registry" ]; then
  warn "filter registry not found at $_hf_registry: asking locally"
  _hf_finish ask "harness-filter (registry-error): no filter registry at $_hf_registry"
fi
if ! _hf_entries="$(jq -c '.filters[] | select(.enabled == true) | {id: .id, settings: .settings}' "$_hf_registry")"; then
  warn "could not parse the filter registry at $_hf_registry: asking locally"
  _hf_finish ask "harness-filter (registry-error): the filter registry at $_hf_registry is unreadable"
fi

# WHY the empty command is answered allow: a PreToolUse hook fires for every
# tool, and only a shell call carries a command, so a payload without one is not
# a deletion candidate. Gating it would prompt on every file read.
_hf_command=""
case "$_hf_payload" in
"") ;;
\{*)
  # WHY best-effort: a harness may hand over JSON this does not know, and jq
  # failing means "no command in the payload" rather than a broken filter.
  if ! _hf_command="$(jq -r '.command // .tool_input.command // ""' <<<"$_hf_payload" 2>&1)"; then
    _hf_command=""
  fi
  ;;
*) _hf_command="$_hf_payload" ;;
esac
if [ -z "$_hf_command" ]; then
  _hf_finish allow "harness-filter (not-a-command): the payload carries no shell command"
fi

_hf_best_decision="allow"
_hf_best_reason="harness-filter (no-filter): no enabled filter made a decision"

while IFS= read -r _hf_entry; do
  if [ -z "$_hf_entry" ]; then
    continue
  fi
  _hf_id="$(jq -r '.id' <<<"$_hf_entry")"
  _hf_settings="$(jq -c '.settings' <<<"$_hf_entry")"
  _hf_filter="$SCRIPT_DIR/filters/$_hf_id.sh"
  _hf_line=""
  if [ ! -f "$_hf_filter" ]; then
    _hf_line="$(printf 'ask\tfilter-error\tno filter script at %s' "$_hf_filter")"
  elif ! _hf_line="$("$_hf_filter" --settings "$_hf_settings" --command "$_hf_command" <<<"$_hf_payload")"; then
    # WHY the filter's own stderr is left alone: it already reached this process's
    # stderr, and merging it into the line would make a plain diagnostic read as
    # the verdict.
    _hf_line="$(printf 'ask\tfilter-error\tthe filter exited non-zero')"
  fi

  _hf_tabs="$(printf '%s' "$_hf_line" | tr -cd '\t' | wc -c | tr -d ' ')"
  if [ "$_hf_tabs" -ne 2 ]; then
    _hf_line="$(printf 'ask\tfilter-error\tthe filter printed no decision line')"
  fi
  _hf_decision="$(printf '%s' "$_hf_line" | cut -f1)"
  _hf_rule="$(printf '%s' "$_hf_line" | cut -f2)"
  _hf_reason="$(printf '%s' "$_hf_line" | cut -f3-)"
  case "$_hf_decision" in
  allow | deny) ;;
  *) _hf_decision="ask" ;;
  esac

  if [ "$(_hf_rank "$_hf_decision")" -gt "$(_hf_rank "$_hf_best_decision")" ]; then
    _hf_best_decision="$_hf_decision"
    _hf_best_reason="$_hf_id ($_hf_rule): $_hf_reason"
  fi
done <<<"$_hf_entries"

_hf_finish "$_hf_best_decision" "$_hf_best_reason"
