#!/usr/bin/env bash
# Test: the POSIX PowerShell profile exports the SSH agent environment.
#
# The profile is a Nix-substituted template, so its behaviour exists only after
# substitution: this suite performs the same replacement src/modules/pwsh.nix
# does (with the values under test) and loads the result in pwsh, which is the
# only way to observe the exported variables.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command pwsh "pwsh is required to load the PowerShell profile"

PROFILE_TEMPLATE="$SCRIPT_DIR/../../src/scripts/shell/init.ps1"
FAKE_SOCKET="/tmp/nucleus-test-gpg-agent.ssh"

# shellcheck disable=SC2016 # reason: PowerShell variable references, not shell expansion
PS_SOCKET_EXPR='$env:SSH_AUTH_SOCK'
# shellcheck disable=SC2016 # reason: PowerShell variable references, not shell expansion
PS_SOCKET_STATE='if ($null -eq $env:SSH_AUTH_SOCK) { "absent" } else { $env:SSH_AUTH_SOCK }'
# shellcheck disable=SC2016 # reason: PowerShell variable references, not shell expansion
PS_TTY_STATE='if ($null -eq $env:GPG_TTY) { "absent" } else { $env:GPG_TTY }'

# make_profile <ssh-auth-sock-value> — substitute the tokens, write the result to
# a temporary .ps1 (pwsh hands an extensionless path to the macOS document
# handler instead of dot-sourcing it) and print its path.
#
# Mirrors the token list in src/modules/pwsh.nix. A token left behind is asserted
# by test_all_tokens_substituted, so drift between the two lists fails loudly
# instead of silently producing a profile with placeholder text in it.
make_profile() {
  local _sock="$1" _out
  _out="$(mktemp -d)/profile.ps1"
  sed \
    -e 's|__MANAGED_PREPEND_PATH__|# substituted for test|' \
    -e 's|__MANAGED_APPEND_PATH__|# substituted for test|' \
    -e 's|"__ENV_CC__"|"cc"|' \
    -e 's|"__ENV_CXX__"|"c++"|' \
    -e 's|"__ENV_LD__"|"ld"|' \
    -e "s|\"__ENV_SSH_AUTH_SOCK__\"|\"$_sock\"|" \
    -e 's|"__DEFAULT_DEV_TOOLS_PATH__"|"/tmp"|' \
    -e 's|"__SSH_AGENT_TTY_BIN__"|"/usr/bin/tty"|' \
    -e 's|"__GPG_CONNECT_AGENT_BIN__"|"/usr/bin/true"|' \
    -e 's|"__AGENT_ENV_VAR_NAMES__"|"NUCLEUS_TEST_AGENT"|' \
    -e 's|"__AGENT_DEVIN_POSIX_PATH__"|"/tmp/nucleus-test-absent-devin"|' \
    "$PROFILE_TEMPLATE" >"$_out"
  printf '%s\n' "$_out"
}

# discard_profile <profile> — remove the temporary directory the profile lives in.
discard_profile() {
  rm -rf "$(dirname -- "$1")"
}

# profile_value <substituted-profile> <powershell-expression>
# Load the profile in a pwsh with no agent in its environment, then print the
# expression, so what is read is what the profile set and nothing inherited.
profile_value() {
  local _profile="$1" _expression="$2"
  env -u SSH_AUTH_SOCK -u GPG_TTY \
    pwsh -NoProfile -Command ". '$_profile'; $_expression" </dev/null 2>&1
}

test_all_tokens_substituted() {
  local _profile _leftover
  _profile="$(make_profile "$FAKE_SOCKET")"
  # check-suppress:suppression_doc: grep exits 1 when no token remains, which is the expected result here.
  _leftover="$(grep -E '__[A-Z_]+__' "$_profile" || true)"
  discard_profile "$_profile"
  if [ -z "$_leftover" ]; then
    assert_pass "every template token is substituted"
  else
    assert_fail "every template token is substituted" "unsubstituted token(s): $_leftover"
  fi
}

test_socket_is_exported() {
  local _profile _actual
  _profile="$(make_profile "$FAKE_SOCKET")"
  _actual="$(profile_value "$_profile" "$PS_SOCKET_EXPR")"
  discard_profile "$_profile"
  if [ "$_actual" = "$FAKE_SOCKET" ]; then
    assert_pass "profile exports SSH_AUTH_SOCK"
  else
    assert_fail "profile exports SSH_AUTH_SOCK" "expected '$FAKE_SOCKET', got '$_actual'"
  fi
}

test_host_without_agent_keeps_env_untouched() {
  local _profile _actual
  _profile="$(make_profile "")"
  _actual="$(profile_value "$_profile" "$PS_SOCKET_STATE")"
  discard_profile "$_profile"
  if [ "$_actual" = "absent" ]; then
    assert_pass "an empty token leaves SSH_AUTH_SOCK unset"
  else
    assert_fail "an empty token leaves SSH_AUTH_SOCK unset" "expected 'absent', got '$_actual'"
  fi
}

test_gpg_tty_is_not_set_without_a_terminal() {
  local _profile _actual
  _profile="$(make_profile "$FAKE_SOCKET")"
  # `tty` reports "not a tty" and exits non-zero when stdin is not a terminal;
  # the profile must not turn that text into GPG_TTY.
  _actual="$(profile_value "$_profile" "$PS_TTY_STATE")"
  discard_profile "$_profile"
  if [ "$_actual" = "absent" ]; then
    assert_pass "GPG_TTY stays unset without a terminal"
  else
    assert_fail "GPG_TTY stays unset without a terminal" "expected 'absent', got '$_actual'"
  fi
}

test_all_tokens_substituted
test_socket_is_exported
test_host_without_agent_keeps_env_untouched
test_gpg_tty_is_not_set_without_a_terminal

finish_tests
