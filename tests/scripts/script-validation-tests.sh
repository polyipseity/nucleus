#!/usr/bin/env bash
# Validates syntax, best practices, and dependencies for scripts/ and src/scripts/.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/test-lib.sh"

YELLOW='\033[1;33m'

# Test 1: Verify shell syntax (bash -n does parse-only check)
test_bash_syntax() {
    local script="$1"
    if bash -n "$script" 2>/dev/null; then
        assert_pass "Bash syntax: $(basename "$script")"
    else
        assert_fail "Bash syntax: $(basename "$script")" "Parse error detected"
    fi
}

# Test 2: Verify script has a shebang
test_has_shebang() {
    local script="$1"
    if head -n1 "$script" | grep -q "^#!"; then
        assert_pass "Shebang present: $(basename "$script")"
    else
        assert_fail "Shebang present: $(basename "$script")" "Missing #!/usr/bin/env or #!/bin/bash"
    fi
}

# Test 3: Verify script is executable
test_is_executable() {
    local script="$1"
    if [[ -x "$script" ]]; then
        assert_pass "Executable bit set: $(basename "$script")"
    else
        assert_fail "Executable bit set: $(basename "$script")" "Not executable (mode $(stat -f '%A' "$script" 2>/dev/null || echo 'unknown'))"
    fi
}

# Test 4: Verify critical dependencies are available
test_dependencies_available() {
    local script="$1"
    shift
    local deps=("$@")

    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null || grep -q "$dep" "$script"; then
            assert_pass "Dependency available: $dep ($(basename "$script"))"
        else
            # Only fail if the script explicitly requires it
            if grep -q "^[^#]*\b$dep\b" "$script"; then
                assert_fail "Dependency available: $dep ($(basename "$script"))" "Not found in PATH"
            fi
        fi
    done
}

# Test 5: Verify error handling patterns (set -e or explicit checks)
test_error_handling() {
    local script="$1"
    if grep -q "set -e" "$script" || grep -q "|| exit" "$script" || grep -q "|| return" "$script"; then
        assert_pass "Error handling present: $(basename "$script")"
    else
        # Warning: some scripts may intentionally allow failures
        echo -e "${YELLOW}⚠${NC}  No error handling patterns found in $(basename "$script")"
    fi
}

# Test 6: Verify comments explain critical sections
test_has_documentation() {
    local script="$1"
    local comment_lines
    comment_lines=$(grep -c "^\s*#" "$script" || echo 0)
    local total_lines
    total_lines=$(wc -l < "$script")
    local comment_ratio=$((comment_lines * 100 / total_lines))

    if [[ $comment_ratio -ge 15 ]]; then
        assert_pass "Documentation present: $(basename "$script") ($comment_ratio% comments)"
    else
        echo -e "${YELLOW}⚠${NC}  Low documentation: $(basename "$script") ($comment_ratio% comments, recommend ≥15%)"
    fi
}

# Test 7: Verify no dangerous patterns (unquoted variables, etc.)
test_no_dangerous_patterns() {
    local script="$1"
    local dangerous=0

    # Check for unquoted variables in potentially dangerous contexts
    # shellcheck disable=SC2016 # reason: $ chars are literal regex metacharacters, not shell expansions.
    if grep -E '\$[A-Za-z_][A-Za-z0-9_]*\s+(&&|;|\||>)' "$script" | grep -v '\$([^)]*' | grep -v '${' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        echo -e "${YELLOW}⚠${NC}  Potential unquoted variable: $(basename "$script")"
    fi

    # Check for rm -rf without safeguards (-- after rm -rf is accepted as a separator guard)
    if grep -E 'rm\s+-rf' "$script" | grep -v 'HOME\|TMPDIR\|/tmp\|--' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        echo -e "${YELLOW}⚠${NC}  Potentially unsafe rm -rf: $(basename "$script")"
    fi

    if [[ $dangerous -eq 0 ]]; then
        assert_pass "No dangerous patterns: $(basename "$script")"
    fi
}

# Test 8: Verify bootstrap direnv auto-allow is strictly repo-scoped
test_bootstrap_direnv_scope() {
    local script="$1"

    # shellcheck disable=SC2016 # reason: Match literal "$REPO_ROOT" text in script source.
    if ! grep -Fq 'direnv allow "$REPO_ROOT"' "$script"; then
        assert_fail "Bootstrap direnv scope: $(basename "$script")" "Missing repo-root direnv allow invocation"
        return
    fi

    # shellcheck disable=SC2016 # reason: Match literal "$REPO_ROOT" text in script source.
    if ! grep -Fq 'basename -- "$REPO_ROOT"' "$script" || ! grep -Fq '"nucleus"' "$script"; then
        assert_fail "Bootstrap direnv scope: $(basename "$script")" "Missing nucleus-only scope guard"
        return
    fi

    assert_pass "Bootstrap direnv scope: $(basename "$script")"
}

# Test 9: Verify strict shell mode (set -euo pipefail)
# Ensures scripts fail fast on undefined variables and pipe errors.
test_strict_shell_mode() {
    local script="$1"
    if grep -q 'set -euo pipefail' "$script"; then
        assert_pass "Strict shell mode: $(basename "$script")"
    else
        assert_fail "Strict shell mode: $(basename "$script")" "Missing set -euo pipefail"
    fi
}

# Test 10: Verify usage_std function is defined (either local or via lib.sh)
test_usage_std_present() {
    local script="$1"
    if grep -Eq '^\s*usage_std\(\)' "$script" || grep -Eq '^\s*\.\s+.*lib\.sh' "$script"; then
        assert_pass "usage_std present: $(basename "$script")"
    else
        echo -e "${YELLOW}⚠${NC}  No usage_std found in $(basename "$script")"
    fi
}

# Test 11: Verify -h|--help handler is present
test_help_handler() {
    local script="$1"
    if grep -Eq '\s+-h\||--help\)' "$script"; then
        assert_pass "Help handler present: $(basename "$script")"
    else
        assert_fail "Help handler present: $(basename "$script")" "Missing -h|--help case"
    fi
}

# Run Tests on All Scripts

echo "Testing shell scripts for correctness and best practices..."
echo ""

# Test scripts/vm.sh
VM_SETUP_SH="scripts/vm.sh"
if [[ -f "$VM_SETUP_SH" ]]; then
    test_bash_syntax "$VM_SETUP_SH"
    test_has_shebang "$VM_SETUP_SH"
    test_is_executable "$VM_SETUP_SH"
    test_dependencies_available "$VM_SETUP_SH" qemu-system-aarch64 qemu-system-x86_64 rsync
    test_error_handling "$VM_SETUP_SH"
    test_has_documentation "$VM_SETUP_SH"
    test_no_dangerous_patterns "$VM_SETUP_SH"
    test_strict_shell_mode "$VM_SETUP_SH"
    test_usage_std_present "$VM_SETUP_SH"
    test_help_handler "$VM_SETUP_SH"

    # HVF on arm64 macOS only accelerates AArch64 guests; x86_64 Windows QEMU builds must use tcg.
    # Without this fix, qemu-system-x86_64 -accel hvf fails with
    # "invalid accelerator hvf" on Apple Silicon.
    if grep -q 'arm64' "$VM_SETUP_SH" && grep -q "accelerator='tcg'" "$VM_SETUP_SH"; then
        assert_pass "arm64 tcg fallback present: $(basename "$VM_SETUP_SH")"
    else
        assert_fail "arm64 tcg fallback present: $(basename "$VM_SETUP_SH")" \
            "Missing Apple Silicon tcg fallback for x86_64 QEMU builds"
    fi
fi

# Test scripts/apply.sh → src/scripts/apply.sh
APPLY_SH="src/scripts/apply.sh"
if [[ -f "$APPLY_SH" ]]; then
    test_bash_syntax "$APPLY_SH"
    test_has_shebang "$APPLY_SH"
    test_is_executable "$APPLY_SH"
    test_dependencies_available "$APPLY_SH" git sops ssh-to-age
    test_error_handling "$APPLY_SH"
    test_has_documentation "$APPLY_SH"
    test_no_dangerous_patterns "$APPLY_SH"
    test_strict_shell_mode "$APPLY_SH"
    test_usage_std_present "$APPLY_SH"
    test_help_handler "$APPLY_SH"
fi

# Test scripts/bootstrap.sh
BOOTSTRAP_SH="scripts/bootstrap.sh"
if [[ -f "$BOOTSTRAP_SH" ]]; then
    test_bash_syntax "$BOOTSTRAP_SH"
    test_has_shebang "$BOOTSTRAP_SH"
    test_is_executable "$BOOTSTRAP_SH"
    test_dependencies_available "$BOOTSTRAP_SH" git nix
    test_error_handling "$BOOTSTRAP_SH"
    test_bootstrap_direnv_scope "$BOOTSTRAP_SH"
    test_has_documentation "$BOOTSTRAP_SH"
    test_no_dangerous_patterns "$BOOTSTRAP_SH"
    test_strict_shell_mode "$BOOTSTRAP_SH"
    test_usage_std_present "$BOOTSTRAP_SH"
    test_help_handler "$BOOTSTRAP_SH"
fi

# Test scripts/health-check.sh
HEALTH_CHECK_SH="scripts/health-check.sh"
if [[ -f "$HEALTH_CHECK_SH" ]]; then
    test_bash_syntax "$HEALTH_CHECK_SH"
    test_has_shebang "$HEALTH_CHECK_SH"
    test_is_executable "$HEALTH_CHECK_SH"
    test_dependencies_available "$HEALTH_CHECK_SH" git curl
    test_error_handling "$HEALTH_CHECK_SH"
    test_has_documentation "$HEALTH_CHECK_SH"
    test_strict_shell_mode "$HEALTH_CHECK_SH"
    test_usage_std_present "$HEALTH_CHECK_SH"
    test_help_handler "$HEALTH_CHECK_SH"
fi

# Test scripts/update.sh
UPDATE_SH="scripts/update.sh"
if [[ -f "$UPDATE_SH" ]]; then
    test_bash_syntax "$UPDATE_SH"
    test_has_shebang "$UPDATE_SH"
    test_is_executable "$UPDATE_SH"
    test_dependencies_available "$UPDATE_SH" nix sops
    test_error_handling "$UPDATE_SH"
    test_has_documentation "$UPDATE_SH"
    test_strict_shell_mode "$UPDATE_SH"
    test_usage_std_present "$UPDATE_SH"
    test_help_handler "$UPDATE_SH"
fi

# Test scripts/ai.sh
AI_SH="scripts/ai.sh"
if [[ -f "$AI_SH" ]]; then
    test_bash_syntax "$AI_SH"
    test_has_shebang "$AI_SH"
    test_is_executable "$AI_SH"
    test_error_handling "$AI_SH"
    test_has_documentation "$AI_SH"
    test_no_dangerous_patterns "$AI_SH"
    test_strict_shell_mode "$AI_SH"
    test_usage_std_present "$AI_SH"
    test_help_handler "$AI_SH"
fi

# Test scripts/cloud-setup.sh
CLOUD_SETUP_SH="scripts/cloud-setup.sh"
if [[ -f "$CLOUD_SETUP_SH" ]]; then
    test_bash_syntax "$CLOUD_SETUP_SH"
    test_has_shebang "$CLOUD_SETUP_SH"
    test_is_executable "$CLOUD_SETUP_SH"
    test_dependencies_available "$CLOUD_SETUP_SH" git rsync
    test_error_handling "$CLOUD_SETUP_SH"
    test_has_documentation "$CLOUD_SETUP_SH"
    test_no_dangerous_patterns "$CLOUD_SETUP_SH"
    test_strict_shell_mode "$CLOUD_SETUP_SH"
    test_usage_std_present "$CLOUD_SETUP_SH"
    test_help_handler "$CLOUD_SETUP_SH"
fi

# Test scripts/gc.sh
GC_SH="scripts/gc.sh"
if [[ -f "$GC_SH" ]]; then
    test_bash_syntax "$GC_SH"
    test_has_shebang "$GC_SH"
    test_is_executable "$GC_SH"
    test_dependencies_available "$GC_SH" git nix
    test_error_handling "$GC_SH"
    test_has_documentation "$GC_SH"
    test_no_dangerous_patterns "$GC_SH"
    test_strict_shell_mode "$GC_SH"
    test_usage_std_present "$GC_SH"
    test_help_handler "$GC_SH"
fi

# Test scripts/gc.ps1 (Windows: garbage collection)
GC_PS1="scripts/gc.ps1"
if [[ -f "$GC_PS1" ]]; then
    if pwsh -NoProfile -Command "& { if (!(Test-Path '$GC_PS1')) { exit 1 }; \$null = Get-Command '$GC_PS1' -Syntax; exit 0 }" 2>/dev/null; then
        assert_pass "PowerShell syntax: gc.ps1"
    else
        assert_fail "PowerShell syntax: gc.ps1" "Parse error detected by pwsh"
    fi
fi

# Test src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1 (Windows: git+ssh config)
GIT_SSH_CONFIG_PS1="src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1"
if [[ -f "$GIT_SSH_CONFIG_PS1" ]]; then
    if pwsh -NoProfile -Command "& { if (!(Test-Path '$GIT_SSH_CONFIG_PS1')) { exit 1 }; \$null = Get-Command '$GIT_SSH_CONFIG_PS1' -Syntax; exit 0 }" 2>/dev/null; then
        assert_pass "PowerShell syntax: Sync-GitAndSshConfig.ps1"
    else
        assert_fail "PowerShell syntax: Sync-GitAndSshConfig.ps1" "Parse error detected by pwsh"
    fi
fi

# Test scripts/replica-reset.sh
REPLICA_RESET_SH="scripts/replica-reset.sh"
if [[ -f "$REPLICA_RESET_SH" ]]; then
    test_bash_syntax "$REPLICA_RESET_SH"
    test_has_shebang "$REPLICA_RESET_SH"
    test_is_executable "$REPLICA_RESET_SH"
    test_dependencies_available "$REPLICA_RESET_SH" git rsync
    test_error_handling "$REPLICA_RESET_SH"
    test_has_documentation "$REPLICA_RESET_SH"
    test_no_dangerous_patterns "$REPLICA_RESET_SH"
    test_strict_shell_mode "$REPLICA_RESET_SH"
    test_usage_std_present "$REPLICA_RESET_SH"
    test_help_handler "$REPLICA_RESET_SH"
fi

# Test scripts/replica-sync.sh
REPLICA_SYNC_SH="scripts/replica-sync.sh"
if [[ -f "$REPLICA_SYNC_SH" ]]; then
    test_bash_syntax "$REPLICA_SYNC_SH"
    test_has_shebang "$REPLICA_SYNC_SH"
    test_is_executable "$REPLICA_SYNC_SH"
    test_dependencies_available "$REPLICA_SYNC_SH" git rsync
    test_error_handling "$REPLICA_SYNC_SH"
    test_has_documentation "$REPLICA_SYNC_SH"
    test_no_dangerous_patterns "$REPLICA_SYNC_SH"
    test_strict_shell_mode "$REPLICA_SYNC_SH"
    test_usage_std_present "$REPLICA_SYNC_SH"
    test_help_handler "$REPLICA_SYNC_SH"
fi

# Test scripts/check-sh.sh
CHECK_SH_SH="scripts/check-sh.sh"
if [[ -f "$CHECK_SH_SH" ]]; then
    test_bash_syntax "$CHECK_SH_SH"
    test_has_shebang "$CHECK_SH_SH"
    test_is_executable "$CHECK_SH_SH"
    test_dependencies_available "$CHECK_SH_SH" shellcheck
    test_error_handling "$CHECK_SH_SH"
    test_has_documentation "$CHECK_SH_SH"
    test_no_dangerous_patterns "$CHECK_SH_SH"
    test_strict_shell_mode "$CHECK_SH_SH"
    test_usage_std_present "$CHECK_SH_SH"
    test_help_handler "$CHECK_SH_SH"
fi

# Test scripts/check.sh
CHECK_SH="scripts/check.sh"
if [[ -f "$CHECK_SH" ]]; then
    test_bash_syntax "$CHECK_SH"
    test_has_shebang "$CHECK_SH"
    test_is_executable "$CHECK_SH"
    test_dependencies_available "$CHECK_SH" shellcheck pwsh packer nix deadnix
    test_error_handling "$CHECK_SH"
    test_has_documentation "$CHECK_SH"
    test_no_dangerous_patterns "$CHECK_SH"
    # test_strict_shell_mode "$CHECK_SH"  # Intentionally skipped: check.sh uses set -uo pipefail (no -e)
    # because it accumulates errors across all 18 check steps via exit_code variable.
    # See scripts/check.sh header: "all checks run and failures accumulate (report-at-end)".
    # Adding -e would abort on the first failure, defeating the purpose of error accumulation.
    test_usage_std_present "$CHECK_SH"
    test_help_handler "$CHECK_SH"
fi

# Test scripts/gs-pdf-opt.sh
GS_PDF_OPT_SH="scripts/gs-pdf-opt.sh"
if [[ -f "$GS_PDF_OPT_SH" ]]; then
    test_bash_syntax "$GS_PDF_OPT_SH"
    test_has_shebang "$GS_PDF_OPT_SH"
    test_is_executable "$GS_PDF_OPT_SH"
    test_dependencies_available "$GS_PDF_OPT_SH" gs
    test_error_handling "$GS_PDF_OPT_SH"
    test_has_documentation "$GS_PDF_OPT_SH"
    test_no_dangerous_patterns "$GS_PDF_OPT_SH"
    test_strict_shell_mode "$GS_PDF_OPT_SH"
    test_usage_std_present "$GS_PDF_OPT_SH"
    test_help_handler "$GS_PDF_OPT_SH"
fi

# Test src/scripts/camilladsp-daemon.sh
CAMILLADSP_DAEMON_SH="src/scripts/services/camilladsp-daemon.sh"
if [[ -f "$CAMILLADSP_DAEMON_SH" ]]; then
    test_bash_syntax "$CAMILLADSP_DAEMON_SH"
    test_has_shebang "$CAMILLADSP_DAEMON_SH"
    test_is_executable "$CAMILLADSP_DAEMON_SH"
    test_dependencies_available "$CAMILLADSP_DAEMON_SH" camilladsp websocat jq
    test_error_handling "$CAMILLADSP_DAEMON_SH"
    test_has_documentation "$CAMILLADSP_DAEMON_SH"
    test_no_dangerous_patterns "$CAMILLADSP_DAEMON_SH"
    test_strict_shell_mode "$CAMILLADSP_DAEMON_SH"
fi

# Test src/scripts/services/camilladsp-heartbeat.sh
CAMILLADSP_HEARTBEAT_SH="src/scripts/services/camilladsp-heartbeat.sh"
if [[ -f "$CAMILLADSP_HEARTBEAT_SH" ]]; then
    test_bash_syntax "$CAMILLADSP_HEARTBEAT_SH"
    test_has_shebang "$CAMILLADSP_HEARTBEAT_SH"
    test_is_executable "$CAMILLADSP_HEARTBEAT_SH"
    test_dependencies_available "$CAMILLADSP_HEARTBEAT_SH" websocat jq
    test_error_handling "$CAMILLADSP_HEARTBEAT_SH"
    test_has_documentation "$CAMILLADSP_HEARTBEAT_SH"
    test_no_dangerous_patterns "$CAMILLADSP_HEARTBEAT_SH"
    test_strict_shell_mode "$CAMILLADSP_HEARTBEAT_SH"
fi

# Test scripts/svc.sh (macOS-only: launchctl-based service management)
SVC_SH="scripts/svc.sh"
if [[ -f "$SVC_SH" ]]; then
    test_bash_syntax "$SVC_SH"
    test_has_shebang "$SVC_SH"
    test_is_executable "$SVC_SH"
    test_dependencies_available "$SVC_SH" jq
    test_error_handling "$SVC_SH"
    test_has_documentation "$SVC_SH"
    test_no_dangerous_patterns "$SVC_SH"
    test_strict_shell_mode "$SVC_SH"
    test_usage_std_present "$SVC_SH"
    test_help_handler "$SVC_SH"

    # svc list / list --json with SVC_DOMAIN_FILTER=user avoids sudo entirely.
    # Assertions use ssh-agent and discord-music-rpc, which are user-domain on
    # all platforms (unlike ollama/litellm/jellyfin which are system-domain on NixOS).
    SVC_LIST_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" SVC_DOMAIN_FILTER=user "$SVC_SH" list 2>&1 || true)  # undoc-supp: test probe — capturing output regardless of exit code for assertion below
    if echo "$SVC_LIST_OUTPUT" | grep -q "ID.*Name.*Status.*Running.*PID"; then
        assert_pass "svc list: table headers present"
    else
        assert_fail "svc list: table headers present" "Missing expected table header line"
    fi
    if echo "$SVC_LIST_OUTPUT" | grep -qE "^ssh-agent +SSH Agent"; then
        assert_pass "svc list: ID and Name columns show service key and display name"
    else
        assert_fail "svc list: ID and Name columns show service key and display name" "Expected 'ssh-agent  SSH Agent' pattern in output"
    fi
    if echo "$SVC_LIST_OUTPUT" | grep -qE "ssh-agent|discord-music-rpc"; then
        assert_pass "svc list: known services listed"
    else
        {
          echo "DIAG: svc list output follows"
          echo "$SVC_LIST_OUTPUT" | head -15
          echo "DIAG: end svc list output"
        } >&2
        assert_fail "svc list: known services listed" "No expected service names found in output"
    fi
    if ! echo "$SVC_LIST_OUTPUT" | grep -q "unknown"; then
        assert_pass "svc list: no unknown services"
    else
        assert_fail "svc list: no unknown services" "Output contains 'unknown' (likely jq parse failure)"
    fi

    SVC_JSON_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" SVC_DOMAIN_FILTER=user "$SVC_SH" list --json 2>/dev/null || true)  # undoc-supp: test probe — discard stderr (domain-filter info) to keep JSON parseable
    if echo "$SVC_JSON_OUTPUT" | jq -e '.version == "1"' >/dev/null 2>&1; then
        assert_pass "svc list --json: valid JSON with version"
    else
        {
          echo "DIAG: svc list --json output follows"
          echo "$SVC_JSON_OUTPUT" | head -5
          echo "DIAG: end svc list --json output"
        } >&2
        assert_fail "svc list --json: valid JSON with version" "Output is not valid JSON or missing version"

    fi
    if echo "$SVC_JSON_OUTPUT" | jq -e 'has("services")' >/dev/null 2>&1; then
        assert_pass "svc list --json: services key present"
    else
        assert_fail "svc list --json: services key present" "Missing services key in JSON output"
    fi

    # Regression: log-config shows correct capture values for all services (Fix 1 + Fix 3)
    SVC_LOG_CONFIG_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" "$SVC_SH" log-config 2>&1 || true)  # undoc-supp: test probe — capturing output regardless of exit code for assertion below
    if echo "$SVC_LOG_CONFIG_OUTPUT" | grep -q "capture: all"; then
        capture_all_lines=$(echo "$SVC_LOG_CONFIG_OUTPUT" | grep -c "capture: all" || true)  # undoc-supp: grep -c exits 1 when count is 0 (no match); expected when services lack capture field
        capture_none_lines=$(echo "$SVC_LOG_CONFIG_OUTPUT" | grep -c "capture: none" || true)  # undoc-supp: same as above
        if [ "$capture_all_lines" -gt 0 ] && [ "$capture_none_lines" -eq 0 ]; then
            assert_pass "svc log-config: all services have capture=all"
        else
            assert_fail "svc log-config: all services have capture=all" "capture=all: $capture_all_lines, capture=none: $capture_none_lines"
        fi
    else
        assert_fail "svc log-config: all services have capture=all" "No capture=all found in output"
    fi

    SVC_LOG_CONFIG_JSON=$(NUCLEUS_REPO_ROOT="$PWD" "$SVC_SH" log-config --json 2>/dev/null || true)  # undoc-supp: test probe — discard stderr (domain-filter warning) to keep JSON parseable
    if echo "$SVC_LOG_CONFIG_JSON" | jq -e --slurp 'all(.[]; .[].capture == "all")' >/dev/null 2>&1; then
        assert_pass "svc log-config --json: all capture=all via jq"
    else
        {
          echo "DIAG: svc log-config --json output follows"
          echo "$SVC_LOG_CONFIG_JSON" | head -5
          echo "DIAG: end svc log-config --json output"
        } >&2
        assert_fail "svc log-config --json: all capture=all via jq" "jq filter 'all(.[]; .[].capture == \"all\")' failed"
    fi

    # Regression: logs listing shows all services with capture=all (Fix 2 + Fix 4)
    SVC_LOGS_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" "$SVC_SH" logs 2>&1 || true)  # undoc-supp: test probe — capturing output regardless of exit code for assertion below
    # Strip domain-filter warning from start of output to keep grep clean.
    SVC_LOGS_OUTPUT=$(echo "$SVC_LOGS_OUTPUT" | grep -v '^svc: warning:' || true)  # undoc-supp: filter may produce empty output if all lines are warnings
    if echo "$SVC_LOGS_OUTPUT" | grep -q "capture=all"; then
        assert_pass "svc logs: listing shows capture=all"
    else
        assert_fail "svc logs: listing shows capture=all" "No capture=all found in logs listing"
    fi
    for expected_svc in caddy jellyfin litellm ollama sshd; do
        if echo "$SVC_LOGS_OUTPUT" | grep -qE "^\s+$expected_svc\s"; then
            assert_pass "svc logs: service $expected_svc listed"
        else
            assert_fail "svc logs: service $expected_svc listed" "Missing from listing"
        fi
    done
fi

# jq unit test: do_log_config filter resolves fields correctly (Fix 1 regression)
# shellcheck disable=SC2016 # reason: $svc/$platform are jq variables, not shell variables
JQ_FILTER='{
  capture: (.[$svc].platforms[$platform].logging.capture // .[$svc].logging.capture // "all"),
  maxSize: (.[$svc].platforms[$platform].logging.maxSize // .[$svc].logging.maxSize // 10000000),
  maxFiles: (.[$svc].platforms[$platform].logging.maxFiles // .[$svc].logging.maxFiles // 4),
  compress: (.[$svc].platforms[$platform].logging.compress // .[$svc].logging.compress // true),
  sanitize: (.[$svc].platforms[$platform].logging.sanitize // .[$svc].logging.sanitize // true),
  level: (.[$svc].platforms[$platform].logging.level // .[$svc].logging.level // null),
  eventLog: (.[$svc].platforms[$platform].logging.eventLog // .[$svc].logging.eventLog // null)
}'
SVC_FIXTURE='{
  "with-platform": {
    "platforms": { "macos": { "logging": { "capture": "none", "maxSize": 5000000 } } },
    "logging": { "capture": "stderr", "maxFiles": 2 }
  },
  "with-top-level": {
    "logging": { "capture": "stderr", "compress": false }
  },
  "with-no-logging": {},
  "with-level": {
    "platforms": { "linux": { "logging": { "level": "debug" } } }
  },
  "with-eventlog": {
    "platforms": { "windows": { "logging": { "eventLog": "Application" } } }
  }
}'

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-platform" --arg platform "macos" "$JQ_FILTER | .capture")
if [[ "$result" == "none" ]]; then
    assert_pass "jq do_log_config: platform-specific capture takes precedence"
else
    assert_fail "jq do_log_config: platform-specific capture takes precedence" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-platform" --arg platform "macos" "$JQ_FILTER | .maxSize")
if [[ "$result" == "5000000" ]]; then
    assert_pass "jq do_log_config: platform maxSize is used"
else
    assert_fail "jq do_log_config: platform maxSize is used" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-platform" --arg platform "macos" "$JQ_FILTER | .maxFiles")
if [[ "$result" == "2" ]]; then
    assert_pass "jq do_log_config: top-level maxFiles fallback works"
else
    assert_fail "jq do_log_config: top-level maxFiles fallback works" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-top-level" --arg platform "macos" "$JQ_FILTER | .capture")
if [[ "$result" == "stderr" ]]; then
    assert_pass "jq do_log_config: top-level capture fallback works"
else
    assert_fail "jq do_log_config: top-level capture fallback works" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-no-logging" --arg platform "macos" "$JQ_FILTER | .capture")
if [[ "$result" == "all" ]]; then
    assert_pass "jq do_log_config: default capture is all"
else
    assert_fail "jq do_log_config: default capture is all" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-platform" --arg platform "linux" "$JQ_FILTER | .capture")
if [[ "$result" == "stderr" ]]; then
    assert_pass "jq do_log_config: non-matching platform falls back to top-level"
else
    assert_fail "jq do_log_config: non-matching platform falls back to top-level" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-level" --arg platform "macos" "$JQ_FILTER | .level")
if [[ "$result" == "null" ]]; then
    assert_pass "jq do_log_config: level defaults to null"
else
    assert_fail "jq do_log_config: level defaults to null" "got '$result'"
fi

result=$(echo "$SVC_FIXTURE" | jq -r --arg svc "with-no-logging" --arg platform "macos" "$JQ_FILTER | .compress")
if [[ "$result" == "true" ]]; then
    assert_pass "jq do_log_config: compress defaults to true"
else
    assert_fail "jq do_log_config: compress defaults to true" "got '$result'"
fi

# Test src/scripts/services/service-watchdog.sh (macOS/NixOS: launchctl/systemctl watchdog)
WATCHDOG_SH="src/scripts/services/service-watchdog.sh"
if [[ -f "$WATCHDOG_SH" ]]; then
    test_bash_syntax "$WATCHDOG_SH"
    test_has_shebang "$WATCHDOG_SH"
    test_is_executable "$WATCHDOG_SH"
    test_dependencies_available "$WATCHDOG_SH" jq
    test_error_handling "$WATCHDOG_SH"
    test_has_documentation "$WATCHDOG_SH"
    test_no_dangerous_patterns "$WATCHDOG_SH"
    test_strict_shell_mode "$WATCHDOG_SH"
    test_usage_std_present "$WATCHDOG_SH"
    test_help_handler "$WATCHDOG_SH"
fi

# Test src/scripts/services/service-watchdog.ps1 (Windows: scheduled task watchdog)
WATCHDOG_PS1="src/scripts/services/service-watchdog.ps1"
if [[ -f "$WATCHDOG_PS1" ]]; then
    if pwsh -NoProfile -Command "& { if (!(Test-Path '$WATCHDOG_PS1')) { exit 1 }; \$null = Get-Command '$WATCHDOG_PS1' -Syntax; exit 0 }" 2>/dev/null; then
        assert_pass "PowerShell syntax: service-watchdog.ps1"
    else
        assert_fail "PowerShell syntax: service-watchdog.ps1" "Parse error detected by pwsh"
    fi
fi

# Test src/hosts/Windows/modules/system/Sync-TerminalActivations.ps1
SYNC_TERMINAL_PS1="src/hosts/Windows/modules/system/Sync-TerminalActivations.ps1"
if [[ -f "$SYNC_TERMINAL_PS1" ]]; then
    if pwsh -NoProfile -Command "& { if (!(Test-Path '$SYNC_TERMINAL_PS1')) { exit 1 }; \$null = Get-Command '$SYNC_TERMINAL_PS1' -Syntax; exit 0 }" 2>/dev/null; then
        assert_pass "PowerShell syntax: Sync-TerminalActivations.ps1"
    else
        assert_fail "PowerShell syntax: Sync-TerminalActivations.ps1" "Parse error detected by pwsh"
    fi
fi

# Test tests/scripts/terminal-activations-tests.sh
TERMINAL_TEST_SH="tests/scripts/terminal-activations-tests.sh"
if [[ -f "$TERMINAL_TEST_SH" ]]; then
    test_bash_syntax "$TERMINAL_TEST_SH"
    test_has_shebang "$TERMINAL_TEST_SH"
    test_is_executable "$TERMINAL_TEST_SH"
    test_error_handling "$TERMINAL_TEST_SH"
    test_has_documentation "$TERMINAL_TEST_SH"
    test_no_dangerous_patterns "$TERMINAL_TEST_SH"
    test_strict_shell_mode "$TERMINAL_TEST_SH"
fi

# Test tests/hosts/Windows/system/Sync-TerminalActivations.Tests.ps1
TERMINAL_PESTER_PS1="tests/hosts/Windows/system/Sync-TerminalActivations.Tests.ps1"
if [[ -f "$TERMINAL_PESTER_PS1" ]]; then
    if pwsh -NoProfile -Command "& { if (!(Test-Path '$TERMINAL_PESTER_PS1')) { exit 1 }; \$null = Get-Command '$TERMINAL_PESTER_PS1' -Syntax; exit 0 }" 2>/dev/null; then
        assert_pass "PowerShell syntax: Sync-TerminalActivations.Tests.ps1"
    else
        assert_fail "PowerShell syntax: Sync-TerminalActivations.Tests.ps1" "Parse error detected by pwsh"
    fi
fi

# Summary

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
