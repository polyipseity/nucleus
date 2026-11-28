#!/usr/bin/env bash
# Tests: the apply-failure collector writes each evidence section without deleting store state.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

collector="$REPO_ROOT/src/scripts/diagnostics/collect-apply-failure.sh"
report="$HOME/apply-failure-report.txt"
stub_bin="$(mktemp -d)"

mkdir -p "$HOME/.cache/nix"
: >"$report"
: >"$HOME/.cache/nix/eval-cache-marker"

cat >"$stub_bin/nix" <<'STUB'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf 'nix-version-stub=2.99\n' ;;
  config) printf 'config-args=%s\n' "${*:3}" ;;
  *) printf 'unexpected nix args: %s\n' "$*" >&2; exit 64 ;;
esac
STUB
cat >"$stub_bin/nix-store" <<'STUB'
#!/usr/bin/env bash
printf 'nix-store-query=%s\n' "$*"
STUB
cat >"$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
printf 'ps-args=%s\n' "$*"
printf 'gc-stub-process pid=4242 command=nix-collect-garbage\n'
STUB
chmod +x "$stub_bin/nix" "$stub_bin/nix-store" "$stub_bin/ps"

fail_bin="$(mktemp -d)"
cat >"$fail_bin/nix" <<'STUB'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf 'stub: version probe failed\n' >&2; exit 1 ;;
  config) printf 'stub: config probe failed\n' >&2; exit 1 ;;
  *) printf 'unexpected nix args: %s\n' "$*" >&2; exit 64 ;;
esac
STUB
chmod +x "$fail_bin/nix"

assert_report_contains() { # <label> <literal> [file]
  local file="${3:-$report}"
  if grep -q -- "$2" "$file"; then
    assert_pass "$1"
  else
    assert_fail "$1" "not found in $file: $2"
  fi
}

if PATH="$stub_bin:$PATH" "$collector" "$report" >"$HOME/collector-stdout" 2>"$HOME/collector-stderr"; then
  assert_pass "collector writes a report"
else
  _rc=$?
  assert_fail "collector writes a report" "rc=$_rc: $(cat "$HOME/collector-stderr")"
fi

assert_report_contains "report contains nix version section" '=== nix version ==='
assert_report_contains "report records the nix version output" 'nix-version-stub=2.99'
assert_report_contains "report contains config section" '=== nix config ==='
assert_report_contains "collector asks nix for the relevant config keys" \
  'config-args=eval-cache keep-derivations keep-outputs min-free max-free'
assert_report_contains "report names the missing derivation" \
  '/nix/store/0rz22bph811zkzy1z5xkfslj3zy19qj0-darwin-system-26.11.ff0e21a.drv'
assert_report_contains "collector queries the failing derivation" \
  'nix-store-query=-q --hash /nix/store/0rz22bph811zkzy1z5xkfslj3zy19qj0-darwin-system-26.11.ff0e21a.drv'
assert_report_contains "collector queries the current generation deriver" \
  'nix-store-query=-q --hash /nix/store/l80mvrmsf16f5b7pjds539vnkn26abyn-darwin-system-26.11.ff0e21a.drv'
assert_report_contains "report records eval cache listing" '=== eval cache listing ==='
assert_report_contains "eval cache listing includes entries" 'eval-cache-marker'
assert_report_contains "report records gc processes" '=== gc processes ==='
assert_report_contains "gc process output reaches the report" 'gc-stub-process pid=4242'

failing_report="$HOME/apply-failure-failing-probes-report.txt"
: >"$failing_report"
if PATH="$fail_bin:$stub_bin:$PATH" "$collector" "$failing_report" >"$HOME/failing-probes-stdout" 2>"$HOME/failing-probes-stderr"; then
  assert_pass "collector completes when nix probes fail"
else
  _rc=$?
  assert_fail "collector completes when nix probes fail" "rc=$_rc: $(cat "$HOME/failing-probes-stderr")"
fi

assert_report_contains "failed-probe report records nix version failure" \
  'nix version query failed' "$failing_report"
assert_report_contains "failed-probe report records nix config failure" \
  'nix config query failed' "$failing_report"
assert_report_contains "failed-probe report contains nix version section" \
  '=== nix version ===' "$failing_report"
assert_report_contains "failed-probe report contains config section" \
  '=== nix config ===' "$failing_report"
assert_report_contains "failed-probe report contains effective config files section" \
  '=== effective config files ===' "$failing_report"
assert_report_contains "failed-probe report contains failing derivation section" \
  '=== failing derivation ===' "$failing_report"
assert_report_contains "failed-probe report contains current generation deriver section" \
  '=== current generation deriver ===' "$failing_report"
assert_report_contains "failed-probe report contains eval cache listing section" \
  '=== eval cache listing ===' "$failing_report"
assert_report_contains "failed-probe report contains gc processes section" \
  '=== gc processes ===' "$failing_report"

if [ -f "$SCRIPT_DIR/../../src/scripts/diagnostics/collect-apply-failure.sh" ] &&
  ! grep -q 'safe-rm\|rip\|rm ' "$SCRIPT_DIR/../../src/scripts/diagnostics/collect-apply-failure.sh"; then
  assert_pass "collector does not delete"
else
  assert_fail "collector does not delete" "collector is missing or names a deletion command"
fi

finish_tests
