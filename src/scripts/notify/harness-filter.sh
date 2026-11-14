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
#   bun filters/<id>.ts --settings <json> --command <text>
#   stdin  the raw hook payload, for a filter that needs more than the command
#   stdout exactly one non-empty line: decision<TAB>rule<TAB>reason
#   decision is allow, ask, or deny; a missing bun, a missing filter, a non-zero
#   exit, or an output that is not exactly one non-empty line carrying three
#   tab-separated fields is recorded as ask with rule `filter-error`, because the
#   filter could not state a verdict.
#
# WHY bun and one file per filter instead of a per-platform twin: the Windows twin
# runs the same `filters/<id>.ts` through the same runtime, so one program decides
# for every harness on every host and no pair of implementations can drift.
#
# The decisions aggregate as deny > ask > allow regardless of registry order, so
# registry order stays readable instead of load-bearing. `ask` means "no decision
# here" and is then put to the configured approval sources, which answer allow or
# deny for a call no filter decides: the runner never allows by omission, because
# that would remove prompting the harness would otherwise do.
#
# Every path prints a document and exits 0, because several harnesses read a
# failed hook as a denial, which would turn a broken registry into a blocked
# session.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# WHY the shared library, not a log path: nucleus-logs owns the log root, the
# line format, and the append, so the runner cannot drift from the log it writes
# into.
# shellcheck source=../lib/logs.sh
. "$SCRIPT_DIR/../lib/logs.sh"
# shellcheck source=../lib/harness-audit.sh
. "$SCRIPT_DIR/../lib/harness-audit.sh"

_hf_start="$(harness_audit_now_ms)"

_hf_harness="${1-}"
_hf_payload=""
if [ ! -t 0 ]; then
  _hf_payload="$(cat)"
fi

# What the approval gate shows the user when no filter decides: the tool the
# harness named and the command it asked about.
# WHY best-effort: a payload this cannot parse still has to reach the gate,
# because the gate, not the runner, decides whether the call runs.
_hf_tool="hook"
_hf_description="${_hf_payload:0:200}"
_hf_description="${_hf_description//$'\n'/ }"
case "$_hf_payload" in
\{*)
  if ! _hf_tool="$(jq -r '.tool_name // .tool // .hook_event_name // "hook"' <<<"$_hf_payload" 2>/dev/null)"; then
    _hf_tool="hook"
  fi
  ;;
esac

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
_hf_finish() { # <decision> <reason> [runner-rule]
  # WHY a third argument: a runner-level outcome has no filter to name, and the
  # rule token is what tells a registry failure apart from a clean `no-filter`.
  _hf_finish_rule="${3-}"
  if [ -z "$_hf_finish_rule" ]; then
    _hf_finish_rule="${_hf_best_rule-}"
  fi
  # WHY best-effort and first: the verdict decides whether a command runs, so a
  # failed append is reported and then ignored. The filter that spoke (if any)
  # and its rule are what makes filter accuracy auditable later.
  if ! (
    _hf_audit_digest="$(printf '%s' "$_hf_payload" | harness_audit_digest)" || exit 1
    _hf_audit_summary="$(printf '%s\n' "$_hf_description" | harness_audit_summary)"
    _hf_audit_source="none"
    if [ -n "${_hf_best_filter-}" ]; then
      _hf_audit_source="filter"
    fi
    harness_audit_log filter "$_hf_harness" "${1-}" "$_hf_audit_source" \
      "${_hf_best_filter-}" "$_hf_finish_rule" \
      "$(($(harness_audit_now_ms) - _hf_start))" \
      "$_hf_audit_summary" "$_hf_audit_digest" ''
  ); then
    warn "could not write the harness audit log"
  fi
  case "${1-}" in
  allow | deny)
    _hf_render "$1" "${2-}"
    exit 0
    ;;
  esac
  # No filter decided, so the configured approval sources answer instead: the
  # same gate every harness hook passes through, asked for the decision word
  # alone because the reason below is this runner's to render.
  _hf_resolver="$SCRIPT_DIR/harness-approval.sh"
  if [ ! -f "$_hf_resolver" ]; then
    warn "no approval resolver at $_hf_resolver: asking locally"
  elif ! _hf_option="$("$_hf_resolver" --plain "$_hf_harness" "$_hf_tool" "$_hf_description")"; then
    warn "the approval resolver failed: asking locally"
  elif [ "$_hf_option" = "allow" ] || [ "$_hf_option" = "deny" ]; then
    _hf_render "$_hf_option" "harness-approval (source)"
    exit 0
  fi
  _hf_render ask "${2-}"
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
  _hf_finish ask "harness-filter (registry-error): the repository root is unknown, so the filter registry cannot be read" registry-error
fi
# check-suppress:config-method: method 4 (runtime direct read) -- the registry is data the runner reads from the live checkout, so a writable symlink into the store or the home directory would freeze the filter list until the next apply
_hf_registry="$_hf_repo_root/src/modules/configs/harness-filters.json"

_hf_entries=""
if [ ! -f "$_hf_registry" ]; then
  warn "filter registry not found at $_hf_registry: asking locally"
  _hf_finish ask "harness-filter (registry-error): no filter registry at $_hf_registry" registry-error
fi
if ! _hf_entries="$(jq -c '.filters[] | select(.enabled == true) | {id: .id, settings: .settings}' "$_hf_registry")"; then
  warn "could not parse the filter registry at $_hf_registry: asking locally"
  _hf_finish ask "harness-filter (registry-error): the filter registry at $_hf_registry is unreadable" registry-error
fi

# WHY the leading whitespace is stripped first: a payload that is JSON behind a
# space or a newline is still JSON, and reading it as a raw command string would
# hand the deletion patterns a text they cannot match, which reads as allow.
_hf_leading="${_hf_payload%%[![:space:]]*}"
_hf_payload="${_hf_payload#"$_hf_leading"}"

# An empty command answers ask: the runner never allows by omission, so a payload
# it cannot inspect keeps the harness's own prompt.
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
  _hf_finish ask "harness-filter (not-a-command): the payload carries no shell command" not-a-command
fi
# The command is what the gate asks about, so it replaces the raw payload, and it
# is collapsed to the one line the terminal prompt and the audit line carry: a
# multi-line command would otherwise reach both verbatim.
_hf_description="$(printf '%s' "$_hf_command" | tr -s '[:space:]' ' ')"
_hf_description="${_hf_description:0:200}"

# WHY ask rather than a hard error: a host without the runtime cannot state a
# verdict, and several harnesses read a failed hook as a denial, so aborting would
# block a session over a missing tool. The warning is what reaches a human; the
# answer is the same filter-error the runner gives a filter that cannot run.
_hf_bun=""
if ! _hf_bun="$(command -v bun)"; then
  warn "bun is not on PATH, so no filter can run: asking locally"
  _hf_finish ask "harness-filter (filter-error): bun is not on PATH, so the filter runtime is missing" filter-error
fi

# WHY empty: "no filter spoke" is not a verdict, so it must not win the
# comparison below. The fallback is ask, and a filter that allows still outranks
# that fallback.
_hf_best_decision=""
_hf_best_reason=""
_hf_best_filter=""
_hf_best_rule=""

while IFS= read -r _hf_entry; do
  if [ -z "$_hf_entry" ]; then
    continue
  fi
  _hf_id="$(jq -r '.id' <<<"$_hf_entry")"
  _hf_settings="$(jq -c '.settings' <<<"$_hf_entry")"
  _hf_filter="$SCRIPT_DIR/filters/$_hf_id.ts"
  _hf_line=""
  if [ ! -f "$_hf_filter" ]; then
    _hf_line="$(printf 'ask\tfilter-error\tno filter script at %s' "$_hf_filter")"
  elif ! _hf_line="$("$_hf_bun" run "$_hf_filter" --settings "$_hf_settings" --command "$_hf_command" <<<"$_hf_payload")"; then
    # WHY the filter's own stderr is left alone: it already reached this process's
    # stderr, and merging it into the line would make a plain diagnostic read as
    # the verdict.
    _hf_line="$(printf 'ask\tfilter-error\tthe filter exited non-zero')"
  fi

  # WHY one line and three fields: the protocol is one verdict per filter. A
  # second line is an answer a harness reading the whole stdout or its last line
  # could act on, and cut reads the newline into the first field, so a multi-line
  # answer used to arrive as a decision that is neither allow nor deny and a rule
  # that is not a rule name. Empty lines are dropped first, because the Windows
  # twin drops empty strings before it counts, and a blank line ahead of a verdict
  # is not a second answer. The Windows twin requires the same two things.
  _hf_line="$(printf '%s\n' "$_hf_line" | sed '/^$/d')"
  _hf_lines="$(printf '%s\n' "$_hf_line" | wc -l | tr -d ' ')"
  _hf_tabs="$(printf '%s' "$_hf_line" | tr -cd '\t' | wc -c | tr -d ' ')"
  if [ "$_hf_lines" -ne 1 ] || [ "$_hf_tabs" -ne 2 ]; then
    _hf_line="$(printf 'ask\tfilter-error\tthe filter printed no decision line')"
  fi
  _hf_decision="$(printf '%s' "$_hf_line" | cut -f1)"
  _hf_rule="$(printf '%s' "$_hf_line" | cut -f2)"
  _hf_reason="$(printf '%s' "$_hf_line" | cut -f3-)"
  case "$_hf_decision" in
  allow | deny) ;;
  *) _hf_decision="ask" ;;
  esac

  if [ -z "$_hf_best_decision" ] || [ "$(_hf_rank "$_hf_decision")" -gt "$(_hf_rank "$_hf_best_decision")" ]; then
    _hf_best_decision="$_hf_decision"
    _hf_best_reason="$_hf_id ($_hf_rule): $_hf_reason"
    _hf_best_filter="$_hf_id"
    _hf_best_rule="$_hf_rule"
  fi
done <<<"$_hf_entries"

if [ -z "$_hf_best_decision" ]; then
  _hf_finish ask "harness-filter (no-filter): no enabled filter produced a verdict" no-filter
fi
_hf_finish "$_hf_best_decision" "$_hf_best_reason"
