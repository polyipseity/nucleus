#!/usr/bin/env bash
# D4: list surfaces for nucleus CLI dynamic providers and machine-readable discovery.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command jq "D4 list-surface tests require jq"

LOGS_SH="$REPO_ROOT/scripts/logs.sh"
CONFIG_SH="$REPO_ROOT/scripts/config.sh"
CLOUD_SH="$REPO_ROOT/scripts/cloud.sh"
CHECK_SH="$REPO_ROOT/scripts/check.sh"
TEST_SH="$REPO_ROOT/scripts/test.sh"
SVC_SH="$REPO_ROOT/scripts/svc.sh"

section 1 "logs --list-logs prints live log names"

tmp_logs="$(mktemp -d)"
trap 'rm -rf "$tmp_logs"' EXIT
: >"$tmp_logs/alpha.log"
: >"$tmp_logs/beta.log"
: >"$tmp_logs/beta.log.1"
: >"$tmp_logs/beta.log.1.gz"
mkdir -p "$tmp_logs/subdir.log" # directories must not be listed
logs_out="$(NUCLEUS_LOG_DIR="$tmp_logs" "$LOGS_SH" --list-logs 2>/dev/null || true)"
if [ "$logs_out" = $'alpha\nbeta' ]; then
  assert_pass "logs --list-logs lists live log base names sorted/unique"
else
  assert_fail "logs --list-logs lists live log base names sorted/unique" "got: $(printf '%s' "$logs_out" | tr '\n' '|')"
fi

section 2 "config list --json emits dotted-key JSON object"

config_json="$("$CONFIG_SH" list --json)"
if printf '%s' "$config_json" | jq -e 'type == "object" and has("applyHistoryLimit") and has("camilladsp.enable")' >/dev/null; then
  assert_pass "config list --json is a dotted-key object"
else
  assert_fail "config list --json is a dotted-key object" "$(printf '%s' "$config_json" | head -c 200)"
fi
config_text="$("$CONFIG_SH" list)"
if printf '%s\n' "$config_text" | grep -q '^applyHistoryLimit='; then
  assert_pass "config list without --json remains key=value text"
else
  assert_fail "config list without --json remains key=value text" "$(printf '%s' "$config_text" | head -c 120)"
fi

section 3 "cloud --list-replicas prints configured replica ids"

cloud_replicas="$("$CLOUD_SH" --list-replicas)"
if printf '%s\n' "$cloud_replicas" | grep -qx 'GoogleDrive' && printf '%s\n' "$cloud_replicas" | grep -qx 'OneDrive' && printf '%s\n' "$cloud_replicas" | grep -qx 'iCloud'; then
  assert_pass "cloud --list-replicas includes configured replicas"
else
  assert_fail "cloud --list-replicas includes configured replicas" "got: $(printf '%s' "$cloud_replicas" | tr '\n' '|')"
fi

section 4 "check/test --list-steps print registered step IDs"

check_steps="$("$CHECK_SH" --list-steps 2>/dev/null)"
if printf '%s\n' "$check_steps" | grep -qx 'code-formatting' && printf '%s\n' "$check_steps" | grep -qx 'app-registry'; then
  assert_pass "check --list-steps prints registered check step IDs"
else
  assert_fail "check --list-steps prints registered check step IDs" "got: $(printf '%s' "$check_steps" | tr '\n' '|')"
fi

test_steps="$("$TEST_SH" --list-steps 2>/dev/null)"
if [ "$test_steps" = $'nix-tests\npowershell-lint-test\nsystem-config-build\nscript-and-framework-tests' ]; then
  assert_pass "test --list-steps prints registered test step IDs in order"
else
  assert_fail "test --list-steps prints registered test step IDs in order" "got: $(printf '%s' "$test_steps" | tr '\n' '|')"
fi

section 5 "svc --list-services and endpoint --list-endpoints"

svc_services="$("$SVC_SH" --list-services 2>/dev/null)"
host="${NUCLEUS_HOST:-}"
if [ -z "$host" ]; then
  case "$(uname -s)" in
  Darwin) host="MacBook" ;;
  Linux) host="NixOS" ;;
  *) host="Unknown" ;;
  esac
fi

svc_with_ep=""
while IFS= read -r svc; do
  [ -n "$svc" ] || continue
  case "$svc" in
  *\\*) continue ;;
  esac
  if jq -e --arg svc "$svc" --arg host "$host" '
    .[$svc].hosts[$host] != null
    and .[$svc].hosts[$host].type != "omitted"
    and ((.[$svc].network // {}) | length) > 0
  ' "$REPO_ROOT/src/modules/services.json" >/dev/null 2>&1; then
    svc_with_ep="$svc"
    break
  fi
done <<<"$svc_services"

if [ -n "$svc_with_ep" ] && printf '%s\n' "$svc_services" | grep -Fqx "$svc_with_ep"; then
  assert_pass "svc --list-services prints host-filtered instance IDs"
else
  assert_fail "svc --list-services prints host-filtered instance IDs" "got: $(printf '%s' "$svc_services" | tr '\n' '|')"
fi

if [ -z "$svc_with_ep" ]; then
  assert_fail "svc endpoint --list-endpoints prints endpoint names (both arg orders)" "no host-declared service with network endpoints found; got: $(printf '%s' "$svc_services" | tr '\n' '|')"
else
  expected_eps="$(jq -r --arg svc "$svc_with_ep" '.[$svc].network | keys[]' "$REPO_ROOT/src/modules/services.json")"
  ep1="$("$SVC_SH" endpoint "$svc_with_ep" --list-endpoints 2>/dev/null || true)"
  ep2="$("$SVC_SH" endpoint --list-endpoints "$svc_with_ep" 2>/dev/null || true)"
  if [ "$ep1" = "$expected_eps" ] && [ "$ep2" = "$expected_eps" ]; then
    assert_pass "svc endpoint --list-endpoints prints endpoint names (both arg orders)"
  else
    assert_fail "svc endpoint --list-endpoints prints endpoint names (both arg orders)" "svc=$svc_with_ep expected=$(printf '%s' "$expected_eps" | tr '\n' '|') ep1=$(printf '%s' "$ep1" | tr '\n' '|') ep2=$(printf '%s' "$ep2" | tr '\n' '|')"
  fi
fi

section 6 "help documents new list surfaces"

logs_help="$("$LOGS_SH" --help 2>&1 || true)"
if printf '%s' "$logs_help" | grep -q -- '--list-logs'; then
  assert_pass "logs --help documents --list-logs"
else
  assert_fail "logs --help documents --list-logs" "missing"
fi
cloud_help="$("$CLOUD_SH" --help 2>&1 || true)"
if printf '%s' "$cloud_help" | grep -q -- '--list-replicas'; then
  assert_pass "cloud --help documents --list-replicas"
else
  assert_fail "cloud --help documents --list-replicas" "missing"
fi
check_help="$("$CHECK_SH" --help 2>&1 || true)"
if printf '%s' "$check_help" | grep -q -- '--list-steps'; then
  assert_pass "check --help documents --list-steps"
else
  assert_fail "check --help documents --list-steps" "missing"
fi
test_help="$("$TEST_SH" --help 2>&1 || true)"
if printf '%s' "$test_help" | grep -q -- '--list-steps'; then
  assert_pass "test --help documents --list-steps"
else
  assert_fail "test --help documents --list-steps" "missing"
fi
svc_help="$("$SVC_SH" --help 2>&1 || true)"
if printf '%s' "$svc_help" | grep -q -- '--list-services'; then
  assert_pass "svc --help documents --list-services"
else
  assert_fail "svc --help documents --list-services" "missing"
fi
if printf '%s' "$svc_help" | grep -q -- '--list-endpoints'; then
  assert_pass "svc --help documents --list-endpoints"
else
  assert_fail "svc --help documents --list-endpoints" "missing"
fi
config_help="$("$CONFIG_SH" --help 2>&1 || true)"
if printf '%s' "$config_help" | grep -q -- 'list \[--json\]'; then
  assert_pass "config --help documents list --json"
else
  assert_fail "config --help documents list --json" "missing"
fi

section 7 "spec --list-* conformance: every spec'd flag is runnable"

# Enumerate all --list-* flags from the CLI spec and verify each has a runnable
# provider on this host. This catches "spec advertises flag, handler missing" drift.
spec_file="$REPO_ROOT/src/modules/completions/nucleus-cli-spec.json"
spec_flags="$(jq -r '.. | strings | select(startswith("--list-"))' "$spec_file" | LC_ALL=C sort -u)"
expected_flags=$'--list-endpoints\n--list-logs\n--list-replicas\n--list-sections\n--list-services\n--list-steps'

if [ "$spec_flags" = "$expected_flags" ]; then
  assert_pass "spec --list-* inventory matches expected set"
else
  assert_fail "spec --list-* inventory matches expected set" "got: $(printf '%s' "$spec_flags" | tr '\\n' '|')"
fi

run_list_flag() {
  local label="$1"
  shift
  local out rc
  out="$("$@" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    assert_pass "$label rc=0 and produces output"
  else
    assert_fail "$label rc=0 and produces output" "rc=$rc out=$(printf '%s' "$out" | head -c 80 | tr '\\n' '|')"
  fi
}

run_list_flag "check --list-steps" "$CHECK_SH" --list-steps
run_list_flag "cloud --list-replicas" "$CLOUD_SH" --list-replicas
run_list_flag "gc --list-logs" env NUCLEUS_LOG_DIR="$tmp_logs" "$REPO_ROOT/scripts/gc.sh" --list-logs
run_list_flag "logs --list-logs" env NUCLEUS_LOG_DIR="$tmp_logs" "$LOGS_SH" --list-logs
run_list_flag "svc --list-services" "$SVC_SH" --list-services
run_list_flag "test --list-steps" "$TEST_SH" --list-steps
run_list_flag "update lockfile --list-sections" "$REPO_ROOT/scripts/update.sh" lockfile --list-sections

# svc endpoint --list-endpoints requires a service argument; reuse the one found in section 5.
if [ -n "$svc_with_ep" ]; then
  run_list_flag "svc endpoint --list-endpoints <svc>" "$SVC_SH" endpoint "$svc_with_ep" --list-endpoints
else
  assert_fail "svc endpoint --list-endpoints <svc> rc=0 and produces output" "no host-declared service with network endpoints found"
fi

finish_tests
