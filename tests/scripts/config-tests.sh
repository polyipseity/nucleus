#!/usr/bin/env bash
# Tests for scripts/config.sh: the runtime config CLI.
#
# The regression this pins is a jq trap, not a shell bug. jq's alternative
# operator treats `false` as false-y, so a filter ending in `// null` turned an
# off boolean into null (the getter then printed nothing and exited 1, which is
# how it reports an unknown key) and `paths(scalars)` dropped every false leaf
# (so the default-off flags were missing from `list`). `set` had the same trap
# twice over: `fromjson? // $raw` stored the string "false" instead of the
# boolean. Windows never had the defect, so this suite also guards POSIX parity
# with scripts/config.ps1.
#
# Run with: bash tests/scripts/config-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CONFIG_SH="$SCRIPT_DIR/../../scripts/config.sh"
readonly CONFIG_SH

require_command jq "the config CLI parses JSON with jq"

# _cfg HOME ARGS... — run the CLI against an isolated config file. The script
# resolves the config path from HOME at startup, so a per-test HOME is the whole
# isolation boundary.
_cfg() { # <home> <args...>
  local home="$1"
  shift
  HOME="$home" bash "$CONFIG_SH" "$@"
}

_cfg_file() { # <home>
  printf '%s\n' "$1/.local/state/nucleus/config.json"
}

_new_home() {
  mktemp -d
}

# _t_get_prints_default_false — the headline case: a default-off boolean.
_t_get_prints_default_false() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_cfg "$home" get harness-approval.enable)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "false" ]; then
    assert_pass "get prints a default-off boolean as false"
  else
    assert_fail "get on a false default" "rc=$rc output=[$out] expected rc=0 output=[false]"
  fi
}

# _t_get_prints_user_false — a false written by the user, through `set` as the
# MANUALs instruct, so the round trip is covered end to end.
_t_get_prints_user_false() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _cfg "$home" set harness-notify.enable false >/dev/null
  out="$(_cfg "$home" get harness-notify.enable)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "false" ]; then
    assert_pass "get prints a user-set false as false"
  else
    assert_fail "get on a user false" "rc=$rc output=[$out]"
  fi
}

# `set <key> false` must store the boolean, not the string: the string would
# survive `get` as a bare false but show up quoted in `list`.
_t_set_false_stores_boolean() {
  local home listed typed=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _cfg "$home" set harness-notify.enable false >/dev/null
  # WHY the quoted field: `harness-notify` contains a hyphen, which jq reads as
  # subtraction unless the field name is quoted.
  jq -e '."harness-notify".enable == false' "$(_cfg_file "$home")" >/dev/null 2>&1 && typed=1
  listed="$(_cfg "$home" list | grep -x 'harness-notify.enable=false' || true)"
  if [ "$typed" -eq 1 ] && [ -n "$listed" ]; then
    assert_pass "set stores a false boolean and list shows it unquoted"
  else
    assert_fail "set false stores a boolean" "boolean-in-file=$typed listed=[$listed]"
  fi
}

_t_get_absent_key_is_unchanged() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  out="$(_cfg "$home" get no-such-section.no-such-key 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    assert_pass "get on an unknown key exits 1 with no output"
  else
    assert_fail "get on an unknown key" "rc=$rc output=[$out] expected rc=1 output=[]"
  fi
}

# A key that exists with the value null is not a missing key: `set` can create
# one outside the defaults, and the walk has to print it.
_t_get_prints_a_present_null() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _cfg "$home" set no-such-section.flag null >/dev/null
  out="$(_cfg "$home" get no-such-section.flag)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "null" ]; then
    assert_pass "get prints a present null and exits 0"
  else
    assert_fail "get on a present null" "rc=$rc output=[$out] expected rc=0 output=[null]"
  fi
}

# null in the user file means "unset" to the merge, so the default shows through.
_t_set_null_restores_the_default() {
  local home out rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _cfg "$home" set harness-approval.enable false >/dev/null
  _cfg "$home" set harness-approval.enable null >/dev/null
  out="$(_cfg "$home" get harness-approval.enable)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "false" ]; then
    assert_pass "setting null restores the default value"
  else
    assert_fail "set null restores the default" "rc=$rc output=[$out]"
  fi
}

_t_get_list_and_section_outputs_are_unchanged() {
  local home rc=0
  home="$(_new_home)"
  trap 'rm -rf "$home"' RETURN
  _cfg "$home" set harness-notify.max-chars 800 >/dev/null
  _cfg "$home" set harness-notify.channels '["ntfy"]' >/dev/null
  _cfg "$home" set camilladsp.heartbeat yes >/dev/null
  local max chars beat section dump
  max="$(_cfg "$home" get harness-notify.max-chars)"
  chars="$(_cfg "$home" get harness-notify.channels | tr -d '\n ')"
  beat="$(_cfg "$home" list | grep -x 'camilladsp.heartbeat="yes"' || true)"
  section="$(_cfg "$home" get harness-approval | tr -d '\n ')"
  dump="$(_cfg "$home" get | jq -c 'keys' 2>/dev/null)" || rc=$?
  if [ "$max" = "800" ] && [ "$chars" = '["ntfy"]' ] && [ -n "$beat" ] &&
    [ "$section" = '{"enable":false,"timeout-seconds":120}' ] &&
    [ "$dump" = '["camilladsp","harness-approval","harness-drive","harness-notify"]' ] && [ "$rc" -eq 0 ]; then
    assert_pass "number, array, bare-string, section and full-dump outputs are unchanged"
  else
    assert_fail "unchanged outputs" "max=[$max] channels=[$chars] heartbeat=[$beat] section=[$section] dump=[$dump] rc=$rc"
  fi
}

section 1 "get and set handle a false boolean"
_t_get_prints_default_false
_t_get_prints_user_false
_t_set_false_stores_boolean
_t_set_null_restores_the_default

section 2 "get keeps its exit-status contract"
_t_get_absent_key_is_unchanged
_t_get_prints_a_present_null

section 3 "the other value shapes are untouched"
_t_get_list_and_section_outputs_are_unchanged

finish_tests
