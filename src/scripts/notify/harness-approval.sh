#!/usr/bin/env bash
# Requests an approval decision for a harness tool call from the enabled sources.
#
#   harness-approval <harness> <tool> <summary> [timeout-seconds]
#       Prints that harness's decision document, so one command serves a hook:
#         cursor  -> {"permission":"allow"|"ask"|"deny"}
#         copilot -> {"hookSpecificOutput":{...,"permissionDecision":"…"}}
#         others  -> plain allow | deny | ask
#   harness-approval --plain <harness> <tool> <summary> [timeout-seconds]
#       Prints the decision word alone, for a caller that renders its own
#       document. `harness-filter` consults the sources that way, so a call no
#       filter decides is answered by the same gate every other call uses.
#
# `ask` means "no source decided" and the harness falls back to its own local
# prompt. Every path prints a decision and exits 0, because some harnesses treat
# a failed hook as a denial, which would turn a broker outage into a blocked
# session.
#
# ~/.local/state/nucleus/config.json:
#   harness-notify.enable                       boolean, default true; false
#                                               disables the whole bridge and
#                                               answers `ask` at once
#   harness-approval.sources                    list of sources, default
#                                               ["prompt"]; an empty list
#                                               disables the gate and answers
#                                               `ask` at once
#   harness-approval.timeout-seconds.<source>   seconds per source, default 0
#
# Sources are independent and race when more than one is enabled; the first
# answer wins and the other is dropped.
#   prompt  asks in the terminal the hook runs under, over /dev/tty. A hook
#           started without a terminal (a GUI editor, a service) answers `ask`
#           instead of reading a denial into its own silence.
#   hermes  publishes a request under <USER root>/state/harness-bridge and waits
#           for `/harness approve <id>` or `/harness deny <id>` on a channel.
#
# A timeout of 0 waits until an answer arrives, so the harness's own hook timeout
# is the ceiling: the hook files declare 3600 s, which outlasts any human answer
# and still ends a session that nobody is watching.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_ha_usage() {
  warn "usage: harness-approval [--plain] <harness> <tool> <summary> [timeout-seconds]"
}

# WHY no flag parsing library: one modifier is the whole vocabulary, and a
# caller that wants the word rather than a document is exactly the case that
# cannot be expressed by the harness name.
_ha_plain=0
if [ "${1-}" = "--plain" ]; then
  _ha_plain=1
  shift
fi

_ha_harness="${1-}"
_ha_tool="${2-}"
_ha_summary="${3-}"
_ha_timeout_arg="${4-}"

# WHY: `ask` is a valid value in every shape, so the neutral answer is always
# expressible.
_ha_render() {
  if [ "$_ha_plain" -eq 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
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

# Only the hook form may omit the action description; every caller passes all
# three, and an empty tool means the caller got its own arguments wrong.
if [ -z "$_ha_tool" ]; then
  _ha_usage
  _ha_finish ask
fi

_ha_defaults='{"harness-notify":{"enable":true},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"hermes":0,"prompt":0}}}'
_ha_user_config='{}'
if [ -f "$HOME/.local/state/nucleus/config.json" ]; then
  # WHY: an unreadable config takes the unparsable exit with its message, since
  # a hook dying under `set -e` prints no decision and Copilot reads that as a
  # denial.
  if ! _ha_user_config="$(cat "$HOME/.local/state/nucleus/config.json")"; then
    warn "could not parse nucleus config: asking locally"
    _ha_finish ask
  fi
fi
if ! _ha_config="$(
  jq -c --argjson defaults "$_ha_defaults" --argjson user "$_ha_user_config" \
    '$defaults * { "harness-notify": ($user["harness-notify"] // {}), "harness-approval": ($user["harness-approval"] // {}) }' <<<'{}'
)"; then
  warn "could not parse nucleus config: asking locally"
  _ha_finish ask
fi

if [ "$(jq -r '."harness-notify".enable' <<<"$_ha_config")" != "true" ]; then
  _ha_finish ask
fi

# WHY: the sources are the gate. None enabled keeps the hooks wired (one config
# key re-enables them) while every tool call is answered `ask` and the harness
# keeps its own prompt.
_ha_prompt=0
_ha_hermes=0
if ! _ha_sources="$(jq -r '."harness-approval".sources[]' <<<"$_ha_config")"; then
  warn "harness-approval.sources is not a list of source names: asking locally"
  _ha_finish ask
fi
# WHY unquoted: jq printed one source per line and the loop wants the words, not
# the newlines.
for _ha_source in $_ha_sources; do
  case "$_ha_source" in
  prompt) _ha_prompt=1 ;;
  hermes) _ha_hermes=1 ;;
  *)
    warn "unknown harness-approval source '$_ha_source': asking locally"
    _ha_finish ask
    ;;
  esac
done
if [ "$_ha_prompt" -eq 0 ] && [ "$_ha_hermes" -eq 0 ]; then
  _ha_finish ask
fi

_ha_timeout_prompt=0
_ha_timeout_hermes=0
for _ha_name in prompt hermes; do
  if ! _ha_value="$(jq -r --arg name "$_ha_name" '."harness-approval"."timeout-seconds"[$name] // 0' <<<"$_ha_config")"; then
    warn "could not read harness-approval.timeout-seconds.$_ha_name: asking locally"
    _ha_finish ask
  fi
  case "$_ha_value" in
  '' | *[!0-9]*)
    warn "harness-approval.timeout-seconds.$_ha_name is not a whole number of seconds: asking locally"
    _ha_finish ask
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
    warn "the timeout argument must be a whole number of seconds: asking locally"
    _ha_finish ask
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
  # unwritable root fails here. Answering `ask` keeps the harness's own prompt
  # instead of letting `set -e` end the run without a document.
  if ! mkdir -p "$_ha_requests" "$_ha_responses"; then
    warn "could not create the harness-bridge state directory"
    _ha_finish ask
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
    _ha_finish ask
  fi
  if ! mv -f "$_ha_request_tmp" "$_ha_request"; then
    rm -f "$_ha_request_tmp"
    warn "could not publish the approval request"
    _ha_finish ask
  fi

  # WHY best-effort: the request file is the source of truth, so a failed
  # notification only means the user reads /harness status instead of being
  # pinged.
  if ! "$SCRIPT_DIR/harness-notify.sh" "$_ha_harness" approval \
    "$_ha_tool: $_ha_summary (reply /harness approve $_ha_id)"; then
    warn "approval notification failed: the request is still visible via /harness status"
  fi
fi

# The prompt reads the terminal the hook runs under, never stdin: a hook's stdin
# is the harness payload, and a hook started without a terminal must answer
# `ask` rather than read its own EOF as a refusal.
_ha_prompt_live="$_ha_prompt"
_ha_tty=0
if [ "$_ha_prompt" -eq 1 ]; then
  if exec 3<>/dev/tty; then
    _ha_tty=1
  else
    warn "no terminal for the prompt source: asking locally"
    _ha_prompt_live=0
  fi
fi

if [ "$_ha_tty" -eq 1 ]; then
  printf 'nucleus approval: %s: %s\n  run it? [y]es / [n]o / [a]lways / [d]on'"'"'t: ' \
    "$_ha_tool" "$_ha_summary" >&3
fi

_ha_answer=""
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
    if ! _ha_answer="$(jq -r '.decision // empty' "$_ha_response")"; then
      warn "could not read the approval response: asking locally"
      _ha_answer=""
    fi
    if [ -n "$_ha_answer" ]; then
      break
    fi
  fi

  if [ "$_ha_prompt_live" -eq 1 ] && [ "$_ha_prompt_deadline" -ne 0 ] &&
    [ "$_ha_now" -ge "$_ha_prompt_deadline" ]; then
    _ha_prompt_live=0
  fi
  if [ "$_ha_hermes_live" -eq 1 ] && [ "$_ha_hermes_deadline" -ne 0 ] &&
    [ "$_ha_now" -ge "$_ha_hermes_deadline" ]; then
    _ha_hermes_live=0
  fi
  if [ "$_ha_prompt_live" -eq 0 ] && [ "$_ha_hermes_live" -eq 0 ]; then
    break
  fi

  if [ "$_ha_prompt_live" -eq 1 ]; then
    _ha_key=""
    if IFS= read -r -n 1 -s -t 1 _ha_key <&3; then
      case "$_ha_key" in
      a | A | y | Y) _ha_answer="allow" ;;
      d | D | n | N) _ha_answer="deny" ;;
      # Any other key is not an answer: the prompt stays live and the next pass
      # reads again, which is what an arrow key or a stray modifier should do.
      *) ;;
      esac
    else
      _ha_rc=$?
      # WHY: `read` reports a timeout above 128 and a closed terminal at or below
      # it, and only the second means nobody can answer any more.
      if [ "$_ha_rc" -le 128 ]; then
        warn "the terminal closed before an answer: asking locally"
        _ha_prompt_live=0
      fi
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

_ha_finish "$_ha_answer"
