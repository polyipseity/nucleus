#!/usr/bin/env bash
# Tests for lib.sh output helpers: F1 grammar, label override, and console
# color detection (NO_COLOR / FORCE_COLOR / CLICOLOR_FORCE / tty).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"

# Run a command against a fresh lib.sh source in a subshell with optional env
# prefix (e.g. "NO_COLOR=1 FORCE_COLOR=0"). $0 is pinned to nucleus-logging-test
# so the derived prefix exercises the "nucleus-" strip and stays deterministic.
# The env prefix is embedded as plain assignments so word splitting is
# intentional (space-separated VAR=value pairs); `:` no-ops when empty.
_run_lib() {
  local env_prefix="$1" cmd="$2"
  bash -c "${env_prefix:-:}; . \"\$1\"; eval \"\$2\"" nucleus-logging-test "$LIB_SH" "$cmd"
}

# ---- Color detection ----

# (a) NO_COLOR non-empty -> no ESC bytes in say/error output.
test_no_color_disables() {
  local out
  out="$(_run_lib 'NO_COLOR=1' 'say hello')"
  if ! echo "$out" | grep -q $'\033'; then
    assert_pass "NO_COLOR=1 disables color on stdout"
  else
    assert_fail "nocolor-stdout" "ESC bytes present with NO_COLOR=1: $(echo "$out" | od -c | head -1)"
  fi
}

test_no_color_disables_stderr() {
  local err
  err="$(_run_lib 'NO_COLOR=1' 'error hello >&2' 2>&1 || true)"
  if ! echo "$err" | grep -q $'\033'; then
    assert_pass "NO_COLOR=1 disables color on stderr"
  else
    assert_fail "nocolor-stderr" "ESC bytes present in error output with NO_COLOR=1"
  fi
}

# (b) FORCE_COLOR=1 -> ESC bytes present even when captured.
test_force_color_on() {
  local out
  out="$(_run_lib 'FORCE_COLOR=1' 'say hello')"
  if echo "$out" | grep -q $'\033'; then
    assert_pass "FORCE_COLOR=1 forces color when captured"
  else
    assert_fail "forcecolor-on" "no ESC bytes with FORCE_COLOR=1"
  fi
}

# (b2) FORCE_COLOR=0 -> off (chalk convention).
test_force_color_zero_off() {
  local out
  out="$(_run_lib 'FORCE_COLOR=0' 'say hello')"
  if ! echo "$out" | grep -q $'\033'; then
    assert_pass "FORCE_COLOR=0 disables color"
  else
    assert_fail "forcecolor-zero" "ESC bytes present with FORCE_COLOR=0"
  fi
}

# CLICOLOR_FORCE set non-empty -> on (deprecated standard, alias of FORCE_COLOR).
test_clicolor_force_on() {
  local out
  out="$(_run_lib 'CLICOLOR_FORCE=1' 'say hello')"
  if echo "$out" | grep -q $'\033'; then
    assert_pass "CLICOLOR_FORCE=1 forces color when captured"
  else
    assert_fail "clicolor-force" "no ESC bytes with CLICOLOR_FORCE=1"
  fi
}

# (c) unset -> no ESC when stdout is not a TTY (capture).
test_no_tty_no_color() {
  local out
  out="$(_run_lib '' 'say hello')"
  if ! echo "$out" | grep -q $'\033'; then
    assert_pass "no color when stdout is not a TTY"
  else
    assert_fail "nontty-color" "ESC bytes present without TTY"
  fi
}

# ---- F1 grammar and label override ----

test_f1_grammar_plain() {
  local out
  out="$(_run_lib 'NO_COLOR=1' 'say hello')"
  if [ "$out" = "logging-test: hello" ]; then
    assert_pass "say emits F1 <cmd>: <msg>"
  else
    assert_fail "f1-say" "expected 'logging-test: hello', got: $out"
  fi
}

test_label_override() {
  local out
  out="$(_run_lib 'NO_COLOR=1' 'say -l ai hello')"
  if [ "$out" = "ai: hello" ]; then
    assert_pass "say -l overrides the command label"
  else
    assert_fail "label-override" "expected 'ai: hello', got: $out"
  fi
}

test_error_grammar() {
  local err
  err="$(_run_lib 'NO_COLOR=1' 'error boom' 2>&1 || true)"
  if [ "$err" = "logging-test: error: boom" ]; then
    assert_pass "error emits F1 <cmd>: error: <msg> on stderr"
  else
    assert_fail "f1-error" "expected 'logging-test: error: boom', got: $err"
  fi
}

# (d) die exits 1 with <cmd>: error: <msg> on stderr.
test_die_exits_1() {
  local rc=0 err
  err="$(_run_lib 'NO_COLOR=1' 'die fatal' 2>&1 || true)"
  _run_lib 'NO_COLOR=1' 'die fatal' >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ] && [ "$err" = "logging-test: error: fatal" ]; then
    assert_pass "die exits 1 with F1 error message"
  else
    assert_fail "die-exit" "expected exit 1 + 'logging-test: error: fatal', got rc=$rc err=$err"
  fi
}

# (f) notice level grammar + label override.
test_notice_grammar() {
  local out
  out="$(_run_lib 'NO_COLOR=1' 'notice hi')"
  if [ "$out" = "logging-test: [notice] hi" ]; then
    assert_pass "notice emits F1 <cmd>: [notice] <msg>"
  else
    assert_fail "f1-notice" "expected 'logging-test: [notice] hi', got: $out"
  fi
}

test_notice_label_override() {
  local out
  out="$(_run_lib 'NO_COLOR=1' 'notice -l ai hi')"
  if [ "$out" = "ai: [notice] hi" ]; then
    assert_pass "notice -l overrides the command label"
  else
    assert_fail "notice-label" "expected 'ai: [notice] hi', got: $out"
  fi
}

# (g) semantic inline coloring: URLs -> underline-cyan, quoted spans -> blue,
# only when color is on; byte-identical otherwise.
test_semantic_url_color_on() {
  local esc=$'\033' out
  local ulcyan="${esc}[4;36m" reset="${esc}[0m"
  out="$(_run_lib 'FORCE_COLOR=1' 'say "check https://example.com"')"
  if printf '%s' "$out" | grep -Fq "${ulcyan}https://example.com${reset}"; then
    assert_pass "URL spans get underline-cyan when color is on"
  else
    assert_fail "semantic-url" "missing underline-cyan URL wrap: $(echo "$out" | od -c | head -1)"
  fi
}

test_semantic_quote_color_on() {
  local esc=$'\033' out
  local blue="${esc}[34m" reset="${esc}[0m"
  out="$(_run_lib 'FORCE_COLOR=1' "say \"account 'jellyfin'\"")"
  if printf '%s' "$out" | grep -Fq "${blue}'jellyfin'${reset}"; then
    assert_pass "single-quoted spans get blue when color is on"
  else
    assert_fail "semantic-quote" "missing blue quote wrap: $(echo "$out" | od -c | head -1)"
  fi
}

test_semantic_color_off_plain() {
  local out
  out="$(_run_lib 'NO_COLOR=1' "say \"account 'jellyfin' at https://example.com\"")"
  if [ "$out" = "logging-test: account 'jellyfin' at https://example.com" ]; then
    assert_pass "semantic coloring is byte-identical when color is off"
  else
    assert_fail "semantic-plain" "expected byte-identical plain output, got: $out"
  fi
}

# (h) TERM=dumb forces color off unless FORCE_COLOR is set.
test_term_dumb_off() {
  local out
  out="$(_run_lib 'TERM=dumb' 'say hello')"
  if ! echo "$out" | grep -q $'\033'; then
    assert_pass "TERM=dumb disables color"
  else
    assert_fail "term-dumb" "ESC bytes present with TERM=dumb"
  fi
}

test_force_color_overrides_term_dumb() {
  local out
  out="$(_run_lib 'TERM=dumb FORCE_COLOR=1' 'say hello')"
  if echo "$out" | grep -q $'\033'; then
    assert_pass "FORCE_COLOR=1 overrides TERM=dumb"
  else
    assert_fail "force-over-term-dumb" "no ESC bytes with FORCE_COLOR=1 TERM=dumb"
  fi
}

# (i) nucleus_expand_log_path: ~ and ~/... templates expand to $HOME; plain
# paths pass through unchanged. The ~/ prefix strip must escape the tilde so
# bash does not tilde-expand the pattern itself.
test_expand_log_path_tilde_slash() {
  local out
  out="$(_run_lib 'HOME=/tmp/nucleus-log-test' 'nucleus_expand_log_path "~/nucleus/logs"')"
  if [ "$out" = "/tmp/nucleus-log-test/nucleus/logs" ]; then
    assert_pass "nucleus_expand_log_path expands ~/ prefix"
  else
    assert_fail "expand-tilde-slash" "expected /tmp/nucleus-log-test/nucleus/logs, got: $out"
  fi
}

test_expand_log_path_bare_tilde() {
  local out
  out="$(_run_lib 'HOME=/tmp/nucleus-log-test' 'nucleus_expand_log_path "~"')"
  if [ "$out" = "/tmp/nucleus-log-test" ]; then
    assert_pass "nucleus_expand_log_path expands bare ~"
  else
    assert_fail "expand-bare-tilde" "expected /tmp/nucleus-log-test, got: $out"
  fi
}

test_expand_log_path_plain() {
  local out
  out="$(_run_lib 'HOME=/tmp/nucleus-log-test' 'nucleus_expand_log_path "/var/log/nucleus"')"
  if [ "$out" = "/var/log/nucleus" ]; then
    assert_pass "nucleus_expand_log_path leaves absolute paths unchanged"
  else
    assert_fail "expand-plain" "expected /var/log/nucleus, got: $out"
  fi
}

# (e) log_sanitize still strips escapes.
test_log_sanitize_strips() {
  local out
  out="$(_run_lib 'FORCE_COLOR=1' 'say hello | log_sanitize')"
  if ! echo "$out" | grep -q $'\033'; then
    assert_pass "log_sanitize strips ESC bytes"
  else
    assert_fail "sanitize" "ESC bytes survived log_sanitize: $(echo "$out" | od -c | head -1)"
  fi
}

# ---- Run tests ----
echo ""
echo "=== logging tests ==="
echo ""

test_no_color_disables
test_no_color_disables_stderr
test_force_color_on
test_force_color_zero_off
test_clicolor_force_on
test_no_tty_no_color
test_f1_grammar_plain
test_label_override
test_error_grammar
test_die_exits_1
test_notice_grammar
test_notice_label_override
test_semantic_url_color_on
test_semantic_quote_color_on
test_semantic_color_off_plain
test_term_dumb_off
test_force_color_overrides_term_dumb
test_expand_log_path_tilde_slash
test_expand_log_path_bare_tilde
test_expand_log_path_plain
test_log_sanitize_strips

echo ""
echo "--- logging tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
