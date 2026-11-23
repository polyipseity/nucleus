#!/usr/bin/env bash
# Tests for the nucleus CLI help/spec drift checker
# (src/scripts/checks/check-steps/10-completions-fresh-drift.py).
#
# The drift checker must reject a flag that appears only in source text and is
# not a declared pwsh parameter or alias. It must also accept a flag that is
# declared as a real pwsh parameter, proving the check uses reflection, not
# source-text matching.
#
# Run with: bash tests/scripts/check-steps/10-completions-fresh-drift-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
DRIFT_PY="$REPO_ROOT/src/scripts/checks/check-steps/10-completions-fresh-drift.py"
readonly REPO_ROOT DRIFT_PY

require_command python3 "python3 is required for drift tests"
require_command pwsh "pwsh is required for pwsh reflection drift tests"

write_spec() { # <file> <app> <flag...>
  local file="$1" app="$2"
  shift 2
  {
    printf '{\n  "apps": [\n    {\n      "name": "%s",\n      "globalFlags": [\n' "$app"
    local first=true flag
    for flag in "$@"; do
      if [ "$first" = true ]; then first=false; else printf ',\n'; fi
      printf '        {"long": "%s", "takesValue": false}' "$flag"
    done
    printf '\n      ],\n      "subcommands": []\n    }\n  ]\n}\n'
  } >"$file"
}

run_drift() { # <fixture-root> <spec-file> <out-file>
  local rc=0
  python3 "$DRIFT_PY" "$1" "$2" >"$3" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

test_source_text_only_flag_fails_reflection() {
  local fixture out rc
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/scripts"
  cat >"$fixture/scripts/fakecmd.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fixture/scripts/fakecmd.sh"
  cat >"$fixture/scripts/fakecmd.ps1" <<'PS1'
[CmdletBinding()]
param(
  [switch]$RealFlag
)
# --sneaky-flag is mentioned in source text but is not a declared parameter.
Write-Output "ok"
PS1
  write_spec "$fixture/spec.json" fakecmd --real-flag --sneaky-flag
  out="$fixture/out.txt"
  rc="$(run_drift "$fixture" "$fixture/spec.json" "$out")"
  if [ "$rc" -eq 1 ] && grep -q 'sneaky-flag' "$out" && grep -q 'not bindable in pwsh' "$out"; then
    assert_pass "source-text-only pwsh flag fails reflection drift check"
  else
    assert_fail "source-text-only pwsh flag fails reflection drift check" "rc=$rc output=$(cat "$out")"
  fi
  rm -rf "$fixture"
}

test_declared_param_passes_reflection() {
  local fixture out rc
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/scripts"
  cat >"$fixture/scripts/fakecmd.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fixture/scripts/fakecmd.sh"
  cat >"$fixture/scripts/fakecmd.ps1" <<'PS1'
[CmdletBinding()]
param(
  [switch]$RealFlag,
  [Alias('sneaky-flag')]
  [switch]$SneakyFlag
)
Write-Output "ok"
PS1
  write_spec "$fixture/spec.json" fakecmd --real-flag --sneaky-flag
  out="$fixture/out.txt"
  rc="$(run_drift "$fixture" "$fixture/spec.json" "$out")"
  if [ "$rc" -eq 0 ] && [ ! -s "$out" ]; then
    assert_pass "declared pwsh parameter/alias passes reflection drift check"
  else
    assert_fail "declared pwsh parameter/alias passes reflection drift check" "rc=$rc output=$(cat "$out")"
  fi
  rm -rf "$fixture"
}

test_source_text_only_flag_fails_reflection
test_declared_param_passes_reflection

finish_tests
