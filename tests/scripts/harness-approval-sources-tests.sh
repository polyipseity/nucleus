#!/usr/bin/env bash
# Suite for the approval gate's sources (src/scripts/notify/harness-approval.sh)
# and for the runner that consults them (src/scripts/notify/harness-filter.sh).
#
# The gate has two independent sources and a matrix of ways to configure them, so
# the cases run the shipped scripts against a config file this suite writes, and
# the terminal is faked rather than inherited:
#
#   * `notty` forks a session with no controlling terminal, which is what a hook
#     started from a GUI harness sees, and proves the prompt source answers `ask`
#     instead of reading its own silence as a denial;
#   * `tty` allocates a pty and types the given text once the prompt is on screen,
#     which is the only way to drive /dev/tty from a suite. The text carries its
#     own newline, because a decision is a line and not a keystroke.
#
# The Hermes side is driven the way the bridge plugin drives it: the suite reads
# the published request and writes the response file the plugin writes.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state
ensure_safe_rm_env

APPROVAL="$REPO_ROOT/src/scripts/notify/harness-approval.sh"
RUNNER="$REPO_ROOT/src/scripts/notify/harness-filter.sh"
readonly APPROVAL RUNNER

require_command jq "the approval gate reads its config, writes requests, and parses responses with jq"
require_command python3 "the faked terminal is a pty driven by python3"
require_command mktemp "temporary directories for the config and the transcripts"

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064 # reason: WORK is resolved and readonly, so expanding now is the same value and survives the exit path
trap "rm -rf '$WORK'" EXIT

# The audit log root is suite-owned: init_test_state points NUCLEUS_REPO_ROOT at a
# tree with no services.json, so leaving this unset would make every case read the
# missing file and warn on the stderr stream the pty helper merges into stdout.
NUCLEUS_LOG_DIR="$WORK/logs"
export NUCLEUS_LOG_DIR

# The faked terminal. `notty` is a new session with no controlling terminal, so
# /dev/tty cannot be opened; `tty` is a pty whose master the helper answers with
# one key once the prompt appears. Both write what the child printed to a file,
# because a pty child's stdout is the terminal, not a pipe.
cat >"$WORK/terminal.py" <<'HELPER'
import os, pty, select, sys, time

mode, key, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = sys.argv[4:]

if mode == 'notty':
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.execvp(cmd[0], cmd)
    _, status = os.waitpid(pid, 0)
    sys.exit(status >> 8)

pid, master = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

out = b''
sent = key == '-'
deadline = time.time() + 30
status = None
while time.time() < deadline:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b''
        if not chunk:
            break
        out += chunk
    if not sent and b'run it?' in out:
        first, sep, rest = key.partition('|')
        os.write(master, first.encode())
        if sep:
            time.sleep(1.6)
            os.write(master, rest.encode())
        sent = True
    waited, state = os.waitpid(pid, os.WNOHANG)
    if waited == pid:
        status = state
        for _ in range(50):
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        break
if status is None:
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
with open(out_path, 'wb') as handle:
    handle.write(out)
sys.exit(status >> 8)
HELPER
readonly TERMINAL_HELPER="$WORK/terminal.py"

CONFIG_PATH="$HOME/.local/state/nucleus/config.json"
# What Enter sends through the pty: a decision is a line, so the cases that answer
# type the word and this newline.
NEWLINE=$'\n'
readonly NEWLINE

write_config() { # <json>
  mkdir -p "$(dirname "$CONFIG_PATH")"
  printf '%s\n' "$1" >"$CONFIG_PATH"
}

# A request left behind by an earlier case would make a "no request" assertion
# pass for the wrong reason, so every case starts from an empty state tree.
clear_state() {
  local _state
  _state="$(find "$HOME" -type d -name harness-bridge -print -quit 2>/dev/null)"
  if [ -n "$_state" ]; then
    rm -rf "$_state"
  fi
  : >"$WORK/hermes.log"
}

pending_requests() {
  local _state
  _state="$(find "$HOME" -type d -name harness-bridge -print -quit 2>/dev/null)"
  [ -n "$_state" ] || return 0
  find "$_state/requests" -name '*.json' -print -quit 2>/dev/null
}

# Recording stub: proves the Hermes source announced the request, without a
# Hermes installation or a network call.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/hermes" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV'; printf '\037%s' "$@"; printf '\nBODY\037'; cat; printf '\n'; } >>"$HARNESS_APPROVAL_LOG"
STUB
chmod +x "$WORK/bin/hermes"
export HARNESS_APPROVAL_LOG="$WORK/hermes.log"
: >"$HARNESS_APPROVAL_LOG"

PATH="$WORK/bin:$PATH"
export PATH

# notty_run <key-for-the-helper-is-ignored> <outfile> <args...>: run the approval
# gate in a session with no terminal, and print what it decided.
notty_run() { # <outfile> <args...>
  local _out="$1"
  shift
  python3 "$TERMINAL_HELPER" notty - "$_out" bash "$APPROVAL" "$@"
}

# `tty_run <typed> <outfile> <args...>`: run the gate on a pty and type <typed>,
# which is the bytes to send, so an answer is a word plus $NEWLINE and a bare key
# is not an answer at all; `-` types nothing, which is what a source nobody
# answers looks like. A `|` pauses 1.6 s between the two halves, which is how a
# slow typist who stops between the letter and Enter is simulated.
tty_run() { # <typed> <outfile> <args...>
  local _typed="$1" _out="$2"
  shift 2
  python3 "$TERMINAL_HELPER" tty "$_typed" "$_out" bash "$APPROVAL" "$@"
}

# The decision is the last line of a transcript that is exactly a decision, which
# is how a pty child's document is told apart from the prompt echo.
decision_of() { # <file>
  tr -d '\r' <"$1" | grep -x -E 'allow|deny|ask' | tail -1 || true
}

elapsed_since() { # <epoch-seconds>
  printf '%s' "$((SECONDS - $1))"
}

wait_for_request() { # <outfile>
  local _i=0
  local _request=""
  while [ "$_i" -lt 60 ]; do
    _request="$(pending_requests)"
    if [ -n "$_request" ]; then
      printf '%s\n' "$_request"
      return 0
    fi
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

answer_request() { # <request-file> <decision>
  local _request="$1" _decision="$2"
  local _state
  _state="$(dirname "$(dirname "$_request")")"
  printf '{"decision":"%s","decided_by":"chat"}\n' "$_decision" \
    >"$_state/responses/$(basename "$_request")"
}

# The audit line names the source that answered, which is the only record of who
# decided a prompt after the harness has moved on.
approval_source() {
  jq -rs 'map(select(.kind == "approval")) | last | .source // ""' "$NUCLEUS_LOG_DIR/harness.log" 2>/dev/null || true
}

section 1 "the sources matrix"

# An absent section takes the shipped default, and only a `prompt` default can turn
# a typed answer into a decision: an accidental `[]` default answers ask here exactly
# as it does without a terminal, so running this under the fake tty is what makes
# the case discriminate.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]}}'
if tty_run "y$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "an absent harness-approval section defaults to the prompt source and takes a typed allow"
  else
    assert_fail "absent section default" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  assert_fail "absent section default" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# The same source with no terminal: a hook started by a GUI harness must answer ask
# at once instead of reading its own EOF as a refusal.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
_start=$SECONDS
if notty_run "$WORK/out" pi bash "rm -rf build" 30 >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -lt 5 ]; then
    assert_pass "the prompt source answers ask at once when the hook has no terminal"
  else
    assert_fail "prompt without a terminal" "out=$(cat "$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "prompt without a terminal" "the gate exited non-zero: $(cat "$WORK/err")"
fi

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":[],"timeout-seconds":{"hermes":30}}}'
_start=$SECONDS
if notty_run "$WORK/out" pi bash "rm -rf build" 30 >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ -z "$(pending_requests)" ] &&
    [ "$(elapsed_since "$_start")" -lt 5 ] && [ ! -s "$HARNESS_APPROVAL_LOG" ]; then
    assert_pass "an empty source list answers ask at once and publishes no request"
  else
    assert_fail "empty sources" "out=$(cat "$WORK/out") requests=$(pending_requests) elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "empty sources" "the gate exited non-zero: $(cat "$WORK/err")"
fi

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
if tty_run "y$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ] && [ "$(approval_source)" = "prompt" ]; then
    assert_pass "the prompt source reads a typed y as allow and is audited as its source"
  else
    assert_fail "prompt allow" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  assert_fail "prompt allow" "the gate exited non-zero: $(cat "$WORK/err")"
fi

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
if tty_run "n$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "deny" ] && [ "$(approval_source)" = "prompt" ]; then
    assert_pass "the prompt source reads a typed n as deny and is audited as its source"
  else
    assert_fail "prompt deny" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  assert_fail "prompt deny" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# The prompt shares the terminal with the harness, so a keystroke aimed at its TUI
# must not answer for the operator: the answer is a line, which needs Enter. A bare
# key therefore leaves the prompt unanswered until its own timeout runs out.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":2}}}'
_start=$SECONDS
if tty_run y "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -ge 2 ]; then
    assert_pass "a bare y without Enter is not an answer and the prompt answers ask at its timeout"
  else
    assert_fail "bare y is not an answer" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "bare y is not an answer" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# The other half of the same rule: the key does decide once Enter arrives, so the
# case above proves Enter is required rather than proving the prompt is deaf.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
if tty_run "y$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "the same y decides allow once Enter arrives"
  else
    assert_fail "y with Enter" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  assert_fail "y with Enter" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# A partial line has to reach the decision: an operator who pauses longer than the
# one-second read timeout between the letter and Enter must still be answered. The
# pty here stays canonical, so the kernel holds the `y` and this case proves only
# that the later Enter picks it up; the raw cases below are what see a read throw
# partial input away.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
if tty_run "y|$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "a y held by the line discipline arrives with the later Enter"
  else
    assert_fail "paused y before Enter" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  assert_fail "paused y before Enter" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# The terminal this rule exists for: a TUI harness puts the shared tty into raw
# mode, where every read timeout consumes what was typed and Enter arrives as a
# bare CR rather than the LF bash treats as end of line. The gate is reached with
# `exec` only after `stty` applied the mode, so a host without a usable stty fails
# here with 97 instead of quietly running the canonical case a second time.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":4}}}'
if python3 "$TERMINAL_HELPER" tty "y"$'\r' "$WORK/out" bash -c "stty raw -echo || exit 97; exec bash '$APPROVAL' pi bash 'rm -rf build'" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "a raw-mode terminal answers allow on y and a bare CR"
  else
    assert_fail "raw-mode answer" "transcript=$(tr -d '\r' <"$WORK/out")"
  fi
else
  _child_rc=$?
  assert_fail "raw-mode answer" "the raw-mode child exited $_child_rc: $(cat "$WORK/err")"
fi

# The pause and raw mode together: the letter is typed, the read times out, and the
# CR arrives a second later. Nothing holds the `y` in raw mode, so this is the case
# that fails when a timed-out read drops what it was handed.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":4}}}'
_start=$SECONDS
if python3 "$TERMINAL_HELPER" tty "y|"$'\r' "$WORK/out" bash -c "stty raw -echo || exit 97; exec bash '$APPROVAL' pi bash 'rm -rf build'" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "a raw-mode y typed before the timeout still answers allow with the later CR"
  else
    assert_fail "paused raw-mode y" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  _child_rc=$?
  assert_fail "paused raw-mode y" "the raw-mode child exited $_child_rc: $(cat "$WORK/err")"
fi

# One control byte inside the line ends it rather than becoming part of the word:
# `yes` followed by ESC and Enter still decides, so a stray key meant for the
# harness TUI cannot turn an answer into a re-prompt.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":4}}}'
_start=$SECONDS
if tty_run "yes"$'\x1b'"$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "allow" ]; then
    assert_pass "a control byte inside the line ends it, so yes with ESC still answers allow"
  else
    assert_fail "control byte in the line" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "control byte in the line" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# An empty line is Enter and nothing else, which is still not an answer.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":2}}}'
_start=$SECONDS
if tty_run "$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -ge 2 ]; then
    assert_pass "an empty line is not an answer and the prompt answers ask at its timeout"
  else
    assert_fail "empty line" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "empty line" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# A word the prompt does not know is not an answer either, and neither is a letter
# inside one: reading a keystroke at a time answered allow on the y in `maybe`.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":2}}}'
_start=$SECONDS
if tty_run "maybe$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -ge 2 ]; then
    assert_pass "an unknown word is not an answer and the prompt answers ask at its timeout"
  else
    assert_fail "unknown word" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "unknown word" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# End of input is the one thing that cannot become an answer: the terminal closing
# ends the source at once instead of waiting out a timeout nobody can beat.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":30}}}'
_start=$SECONDS
if tty_run $'\x04' "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -lt 5 ]; then
    assert_pass "end of input on the terminal ends the prompt source and answers ask at once"
  else
    assert_fail "end of input" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "end of input" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# The prompt's own finite timeout: nobody types anything, so the source gives up
# and the decision falls through to the harness.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt"],"timeout-seconds":{"prompt":2}}}'
_start=$SECONDS
if tty_run - "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$(elapsed_since "$_start")" -lt 10 ]; then
    assert_pass "an unanswered prompt stops at its own timeout and answers ask"
  else
    assert_fail "prompt timeout" "transcript=$(tr -d '\r' <"$WORK/out") elapsed=$(elapsed_since "$_start")s"
  fi
else
  assert_fail "prompt timeout" "the gate exited non-zero: $(cat "$WORK/err")"
fi

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}'
tty_run - "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err" &
_approval_pid=$!
if _request="$(wait_for_request)"; then
  answer_request "$_request" allow
  if wait "$_approval_pid"; then
    if [ "$(decision_of "$WORK/out")" = "allow" ] && [ -s "$HARNESS_APPROVAL_LOG" ] &&
      [ -z "$(pending_requests)" ]; then
      assert_pass "the hermes source publishes a request, announces it, and takes the remote answer"
    else
      assert_fail "hermes allow" "out=$(cat "$WORK/out") log=$(head -1 "$HARNESS_APPROVAL_LOG") requests=$(pending_requests)"
    fi
  else
    assert_fail "hermes allow" "the gate exited non-zero: $(cat "$WORK/err")"
  fi
else
  kill "$_approval_pid" 2>/dev/null || true
  wait "$_approval_pid" 2>/dev/null || true
  assert_fail "hermes allow" "no request file appeared"
fi

# A finite per-source timeout is honoured: the request waits out its seconds,
# then the run ends with ask and the request is consumed rather than left pending.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":2}}}'
_start=$SECONDS
if tty_run - "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  _elapsed="$(elapsed_since "$_start")"
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ "$_elapsed" -ge 2 ] && [ "$_elapsed" -lt 15 ] &&
    [ -z "$(pending_requests)" ]; then
    assert_pass "the hermes source stops at its per-source timeout and clears the request"
  else
    assert_fail "hermes timeout" "out=$(cat "$WORK/out") elapsed=${_elapsed}s requests=$(pending_requests)"
  fi
else
  assert_fail "hermes timeout" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# 0 means never: the wait outlives the same window that ended the case above, and
# still takes the answer when it arrives.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":0}}}'
tty_run - "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err" &
_approval_pid=$!
if _request="$(wait_for_request)"; then
  sleep 4
  if kill -0 "$_approval_pid" 2>/dev/null; then
    answer_request "$_request" deny
    if wait "$_approval_pid"; then
      if [ "$(decision_of "$WORK/out")" = "deny" ]; then
        assert_pass "a timeout of 0 keeps waiting past the bounded observation window and still takes the answer"
      else
        assert_fail "infinite hermes timeout" "out=$(cat "$WORK/out")"
      fi
    else
      assert_fail "infinite hermes timeout" "the gate exited non-zero: $(cat "$WORK/err")"
    fi
  else
    wait "$_approval_pid" 2>/dev/null || true
    assert_fail "infinite hermes timeout" "the gate stopped before the response file was written"
  fi
else
  kill "$_approval_pid" 2>/dev/null || true
  wait "$_approval_pid" 2>/dev/null || true
  assert_fail "infinite hermes timeout" "no request file appeared"
fi

# The document each harness reads is still rendered from whatever the sources
# answered: a hook that calls the resolver directly gets its own shape, not a word.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}'
python3 "$TERMINAL_HELPER" notty - "$WORK/out" bash "$APPROVAL" cursor beforeShellExecution "rm -rf build" >/dev/null 2>"$WORK/err" &
_approval_pid=$!
if _request="$(wait_for_request)"; then
  answer_request "$_request" deny
  if wait "$_approval_pid"; then
    if jq -e '.permission == "deny"' "$WORK/out" >/dev/null 2>&1; then
      assert_pass "a remote decision is rendered as the calling harness's document"
    else
      assert_fail "cursor document" "document=$(cat "$WORK/out")"
    fi
  else
    assert_fail "cursor document" "the gate exited non-zero: $(cat "$WORK/err")"
  fi
else
  kill "$_approval_pid" 2>/dev/null || true
  wait "$_approval_pid" 2>/dev/null || true
  assert_fail "cursor document" "no request file appeared"
fi

section 2 "the race"

# Prompt first: the typed answer wins while the request is still pending, so the
# run ends at once. The announce log is what proves the other source was live: the
# request file itself is published and consumed inside the same second.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt","hermes"],"timeout-seconds":{"prompt":30,"hermes":60}}}'
_start=$SECONDS
if tty_run "y$NEWLINE" "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err"; then
  _elapsed="$(elapsed_since "$_start")"
  if [ "$(decision_of "$WORK/out")" = "allow" ] && [ -s "$HARNESS_APPROVAL_LOG" ] &&
    [ -z "$(pending_requests)" ] && [ "$_elapsed" -lt 20 ]; then
    assert_pass "with both sources enabled the typed prompt wins and the request is cleaned up"
  else
    assert_fail "race prompt-first" "out=$(cat "$WORK/out") log=$(head -1 "$HARNESS_APPROVAL_LOG") requests=$(pending_requests) elapsed=${_elapsed}s"
  fi
else
  assert_fail "race prompt-first" "the gate exited non-zero: $(cat "$WORK/err")"
fi

# Hermes first: the response wins while the prompt is unanswered, and the run ends
# without waiting for the terminal's own timeout.
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["prompt","hermes"],"timeout-seconds":{"prompt":60,"hermes":60}}}'
_start=$SECONDS
tty_run - "$WORK/out" pi bash "rm -rf build" >/dev/null 2>"$WORK/err" &
_approval_pid=$!
if _request="$(wait_for_request)"; then
  answer_request "$_request" deny
  if wait "$_approval_pid"; then
    _elapsed="$(elapsed_since "$_start")"
    if [ "$(decision_of "$WORK/out")" = "deny" ] && [ "$_elapsed" -lt 30 ] &&
      [ -z "$(pending_requests)" ]; then
      assert_pass "with both sources enabled the remote answer wins without waiting for the prompt timeout"
    else
      assert_fail "race hermes-first" "out=$(cat "$WORK/out") elapsed=${_elapsed}s requests=$(pending_requests)"
    fi
  else
    assert_fail "race hermes-first" "the gate exited non-zero: $(cat "$WORK/err")"
  fi
else
  kill "$_approval_pid" 2>/dev/null || true
  wait "$_approval_pid" 2>/dev/null || true
  assert_fail "race hermes-first" "no request file appeared"
fi

section 3 "configuration mistakes fail open"

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["telegram"],"timeout-seconds":{"hermes":30}}}'
if notty_run "$WORK/out" pi bash "rm -rf build" 30 >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ] && [ -z "$(pending_requests)" ]; then
    assert_pass "an unknown source name answers ask rather than waiting on a source that cannot answer"
  else
    assert_fail "unknown source" "out=$(cat "$WORK/out") requests=$(pending_requests)"
  fi
else
  assert_fail "unknown source" "the gate exited non-zero: $(cat "$WORK/err")"
fi

clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":"prompt"}}'
if notty_run "$WORK/out" pi bash "rm -rf build" 10 >/dev/null 2>"$WORK/err"; then
  if [ "$(decision_of "$WORK/out")" = "ask" ]; then
    assert_pass "a source list that is not a list answers ask"
  else
    assert_fail "sources not a list" "out=$(cat "$WORK/out")"
  fi
else
  assert_fail "sources not a list" "the gate exited non-zero: $(cat "$WORK/err")"
fi

section 4 "the runner consults the same sources"

# A payload the filters leave undecided is answered by the sources, and the
# runner renders the harness's own document. The shipped registry asks for an
# unproven redirect, and the fixture pins that value in its own copy so the case
# states the setting it depends on: the fixture carries that one file, and the
# runner still resolves its filters beside itself.
GATE_TREE="$WORK/gate-tree"
mkdir -p "$GATE_TREE/src/modules/configs"
printf '%s\n' '{"filters":[{"enabled":true,"id":"safe-delete","settings":{"unproven":"ask"}}]}' \
  >"$GATE_TREE/src/modules/configs/harness-filters.json"
clear_state
write_config '{"harness-notify":{"channels":["telegram"]},"harness-approval":{"sources":["hermes"],"timeout-seconds":{"hermes":30}}}'
printf '%s' '{"tool_name":"runInTerminal","tool_input":{"command":"rm x"}}' >"$WORK/payload"
python3 "$TERMINAL_HELPER" notty - "$WORK/out" bash -c \
  "NUCLEUS_REPO_ROOT='$GATE_TREE' bash '$RUNNER' copilot <'$WORK/payload'" >/dev/null 2>"$WORK/err" &
_runner_pid=$!
if _request="$(wait_for_request)"; then
  answer_request "$_request" deny
  if wait "$_runner_pid"; then
    if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$WORK/out" >/dev/null 2>&1 &&
      [ -z "$(pending_requests)" ]; then
      assert_pass "an undecided call is answered by the sources and rendered as the harness document"
    else
      assert_fail "runner consults sources" "document=$(cat "$WORK/out")"
    fi
  else
    assert_fail "runner consults sources" "the runner exited non-zero: $(cat "$WORK/err")"
  fi
else
  kill "$_runner_pid" 2>/dev/null || true
  wait "$_runner_pid" 2>/dev/null || true
  assert_fail "runner consults sources" "the runner published no request: $(cat "$WORK/out")"
fi

finish_tests
