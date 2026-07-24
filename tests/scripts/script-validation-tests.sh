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
        echo -e "ℹ  Low documentation: $(basename "$script") ($comment_ratio% comments, recommend ≥15%): informational"
    fi
}

# Test 7: Verify no dangerous patterns (unquoted variables, etc.)
test_no_dangerous_patterns() {
    local script="$1"
    local dangerous=0

    # Check for unquoted variables in potentially dangerous contexts
    # shellcheck disable=SC2016 # reason: $ chars are literal regex metacharacters, not shell expansions.
    if grep -E '\$[A-Za-z_][A-Za-z0-9_]*\s+(&&|;|\||>)' "$script" | grep -v '\$([^)]*' | grep -v '${' | grep -v 'as \$' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        assert_fail "Potential unquoted variable: $(basename "$script")" "Found unquoted variable in dangerous context (&&, ;, |, >)"
    fi

    # Check for rm -rf without safeguards (-- after rm -rf is accepted as a separator guard)
    if grep -E 'rm\s+-rf' "$script" | grep -v 'HOME\|TMPDIR\|/tmp\|--' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        assert_fail "Potentially unsafe rm -rf: $(basename "$script")" "Found rm -rf without HOME/TMPDIR/tmp/-- guard"
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

# Source PARALLEL_JOBS for parallel execution
. "$SCRIPT_DIR/../../src/scripts/lib/lib.sh"

# Temp directory for parallel worker output
_TEST_TMPDIR=$(mktemp -d) || { echo "FATAL: failed to create temp dir"; exit 1; }
trap 'rm -rf "$_TEST_TMPDIR"' EXIT

# Worker function: runs a single script's tests in a subshell.
# Each worker sources test-lib.sh for fresh counters, runs the tests,
# and writes structured output to its temp file.
_run_script_worker() {
  local _script_path="$1"
  local _worker_id="$2"
  local _out_file
  _out_file="$_TEST_TMPDIR/worker_$(printf '%02d' "$_worker_id").out"

  # Run in subshell for isolation
  (
    set -euo pipefail
    . "$SCRIPT_DIR/test-lib.sh"

    [[ ! -f "$_script_path" ]] && exit 0

    case "$_script_path" in
      ######################################################################
      # scripts/vm.sh
      ######################################################################
      scripts/vm.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" qemu-system-aarch64 qemu-system-x86_64 rsync
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        if grep -q 'arm64' "$_script_path" && grep -q "accelerator='tcg'" "$_script_path"; then
          assert_pass "arm64 tcg fallback present: $(basename "$_script_path")"
        else
          assert_fail "arm64 tcg fallback present: $(basename "$_script_path")" \
            "Missing Apple Silicon tcg fallback for x86_64 QEMU builds"
        fi
        ;;

      ######################################################################
      # src/scripts/apply.sh
      ######################################################################
      src/scripts/apply.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git sops ssh-to-age
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/bootstrap.sh
      ######################################################################
      scripts/bootstrap.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git nix
        test_error_handling "$_script_path"
        test_bootstrap_direnv_scope "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/health-check.sh
      ######################################################################
      scripts/health-check.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git curl
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/update.sh
      ######################################################################
      scripts/update.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" nix sops
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/ai.sh
      ######################################################################
      scripts/ai.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/cloud-setup.sh
      ######################################################################
      scripts/cloud-setup.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git rsync
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/gc.sh
      ######################################################################
      scripts/gc.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git nix
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/gc.ps1
      ######################################################################
      scripts/gc.ps1)
        if pwsh -NoProfile -Command "& { if (!(Test-Path '$_script_path')) { exit 1 }; \$null = Get-Command '$_script_path' -Syntax; exit 0 }" 2>/dev/null; then
          assert_pass "PowerShell syntax: gc.ps1"
        else
          assert_fail "PowerShell syntax: gc.ps1" "Parse error detected by pwsh"
        fi
        ;;

      ######################################################################
      # src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1
      ######################################################################
      src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1)
        if pwsh -NoProfile -Command "& { if (!(Test-Path '$_script_path')) { exit 1 }; \$null = Get-Command '$_script_path' -Syntax; exit 0 }" 2>/dev/null; then
          assert_pass "PowerShell syntax: Sync-GitAndSshConfig.ps1"
        else
          assert_fail "PowerShell syntax: Sync-GitAndSshConfig.ps1" "Parse error detected by pwsh"
        fi
        ;;

      ######################################################################
      # scripts/replica-reset.sh
      ######################################################################
      scripts/replica-reset.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git rsync
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/replica-sync.sh
      ######################################################################
      scripts/replica-sync.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" git rsync
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/check-sh.sh
      ######################################################################
      scripts/check-sh.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" shellcheck
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/check.sh
      ######################################################################
      scripts/check.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" shellcheck pwsh packer nix deadnix
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        # test_strict_shell_mode intentionally skipped: check.sh uses set -uo pipefail (no -e)
        # because it accumulates errors across all steps via exit_code variable.
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # scripts/gs-pdf-opt.sh
      ######################################################################
      scripts/gs-pdf-opt.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" gs
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # src/scripts/services/camilladsp-daemon.sh
      ######################################################################
      src/scripts/services/camilladsp-daemon.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" camilladsp websocat jq
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        ;;

      ######################################################################
      # src/scripts/services/camilladsp-heartbeat.sh
      ######################################################################
      src/scripts/services/camilladsp-heartbeat.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" websocat jq
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        ;;

      ######################################################################
      # src/scripts/services/service-watchdog.sh
      ######################################################################
      src/scripts/services/service-watchdog.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" jq
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"
        ;;

      ######################################################################
      # src/scripts/services/service-watchdog.ps1
      ######################################################################
      src/scripts/services/service-watchdog.ps1)
        if pwsh -NoProfile -Command "& { if (!(Test-Path '$_script_path')) { exit 1 }; \$null = Get-Command '$_script_path' -Syntax; exit 0 }" 2>/dev/null; then
          assert_pass "PowerShell syntax: service-watchdog.ps1"
        else
          assert_fail "PowerShell syntax: service-watchdog.ps1" "Parse error detected by pwsh"
        fi
        ;;

      ######################################################################
      # src/hosts/Windows/modules/system/Sync-TerminalActivation.ps1
      ######################################################################
      src/hosts/Windows/modules/system/Sync-TerminalActivation.ps1)
        if pwsh -NoProfile -Command "& { if (!(Test-Path '$_script_path')) { exit 1 }; \$null = Get-Command '$_script_path' -Syntax; exit 0 }" 2>/dev/null; then
          assert_pass "PowerShell syntax: Sync-TerminalActivation.ps1"
        else
          assert_fail "PowerShell syntax: Sync-TerminalActivation.ps1" "Parse error detected by pwsh"
        fi
        ;;

      ######################################################################
      # tests/hosts/Windows/system/Sync-TerminalActivation.Tests.ps1
      ######################################################################
      tests/hosts/Windows/system/Sync-TerminalActivation.Tests.ps1)
        if pwsh -NoProfile -Command "& { if (!(Test-Path '$_script_path')) { exit 1 }; \$null = Get-Command '$_script_path' -Syntax; exit 0 }" 2>/dev/null; then
          assert_pass "PowerShell syntax: Sync-TerminalActivation.Tests.ps1"
        else
          assert_fail "PowerShell syntax: Sync-TerminalActivation.Tests.ps1" "Parse error detected by pwsh"
        fi
        ;;

      ######################################################################
      # tests/scripts/terminal-activations-tests.sh
      ######################################################################
      tests/scripts/terminal-activations-tests.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        ;;

      ######################################################################
      # scripts/svc.sh (macOS-only: launchctl-based service management)
      ######################################################################
      scripts/svc.sh)
        test_bash_syntax "$_script_path"
        test_has_shebang "$_script_path"
        test_is_executable "$_script_path"
        test_dependencies_available "$_script_path" jq
        test_error_handling "$_script_path"
        test_has_documentation "$_script_path"
        test_no_dangerous_patterns "$_script_path"
        test_strict_shell_mode "$_script_path"
        test_usage_std_present "$_script_path"
        test_help_handler "$_script_path"

        # svc list / list --json with SVC_DOMAIN_FILTER=user avoids sudo entirely.
        _svc_list_output=$(NUCLEUS_REPO_ROOT="$PWD" SVC_DOMAIN_FILTER=user "$_script_path" list 2>&1 || true)  # check-suppress:suppression_doc: test probe — capturing output regardless of exit code for assertion below
        if echo "$_svc_list_output" | grep -q "ID.*Name.*Status.*Running.*PID"; then
          assert_pass "svc list: table headers present"
        else
          assert_fail "svc list: table headers present" "Missing expected table header line"
        fi
        if echo "$_svc_list_output" | grep -qE "^ssh-agent +SSH Agent"; then
          assert_pass "svc list: ID and Name columns show service key and display name"
        else
          assert_fail "svc list: ID and Name columns show service key and display name" "Expected 'ssh-agent  SSH Agent' pattern in output"
        fi
        if echo "$_svc_list_output" | grep -qE "ssh-agent|discord-music-rpc"; then
          assert_pass "svc list: known services listed"
        else
          {
            echo "DIAG: svc list output follows"
            echo "$_svc_list_output" | head -15
            echo "DIAG: end svc list output"
          } >&2
          assert_fail "svc list: known services listed" "No expected service names found in output"
        fi
        if ! echo "$_svc_list_output" | grep -q "unknown"; then
          assert_pass "svc list: no unknown services"
        else
          assert_fail "svc list: no unknown services" "Output contains 'unknown' (likely jq parse failure)"
        fi

        _svc_json_output=$(NUCLEUS_REPO_ROOT="$PWD" SVC_DOMAIN_FILTER=user "$_script_path" list --json 2>/dev/null || true)  # check-suppress:suppression_doc: test probe — discard stderr (domain-filter info) to keep JSON parseable
        if echo "$_svc_json_output" | jq -e '.version == "1"' >/dev/null 2>&1; then
          assert_pass "svc list --json: valid JSON with version"
        else
          {
            echo "DIAG: svc list --json output follows"
            echo "$_svc_json_output" | head -5
            echo "DIAG: end svc list --json output"
          } >&2
          assert_fail "svc list --json: valid JSON with version" "Output is not valid JSON or missing version"
        fi
        if echo "$_svc_json_output" | jq -e 'has("services")' >/dev/null 2>&1; then
          assert_pass "svc list --json: services key present"
        else
          assert_fail "svc list --json: services key present" "Missing services key in JSON output"
        fi

        # Regression: log-config shows correct capture values for all services
        _svc_log_config_output=$(NUCLEUS_REPO_ROOT="$PWD" "$_script_path" log-config 2>&1 || true)  # check-suppress:suppression_doc: test probe — capturing output regardless of exit code for assertion below
        if echo "$_svc_log_config_output" | grep -q "capture: all"; then
          _capture_all_lines=$(echo "$_svc_log_config_output" | grep -c "capture: all" || true)  # check-suppress:suppression_doc: grep -c exits 1 when count is 0
          _capture_none_lines=$(echo "$_svc_log_config_output" | grep -c "capture: none" || true)  # check-suppress:suppression_doc: same
          if [ "$_capture_all_lines" -gt 0 ] && [ "$_capture_none_lines" -eq 0 ]; then
            assert_pass "svc log-config: all services have capture=all"
          else
            assert_fail "svc log-config: all services have capture=all" "capture=all: $_capture_all_lines, capture=none: $_capture_none_lines"
          fi
        else
          assert_fail "svc log-config: all services have capture=all" "No capture=all found in output"
        fi

        _svc_log_config_json=$(NUCLEUS_REPO_ROOT="$PWD" "$_script_path" log-config --json 2>/dev/null || true)  # check-suppress:suppression_doc: test probe — discard stderr
        if echo "$_svc_log_config_json" | jq -e --slurp 'all(.[]; .[].capture == "all")' >/dev/null 2>&1; then
          assert_pass "svc log-config --json: all capture=all via jq"
        else
          {
            echo "DIAG: svc log-config --json output follows"
            echo "$_svc_log_config_json" | head -5
            echo "DIAG: end svc log-config --json output"
          } >&2
          assert_fail "svc log-config --json: all capture=all via jq" "jq filter 'all(.[]; .[].capture == \"all\")' failed"
        fi

        # Regression: logs listing shows all services with capture=all
        _svc_logs_output=$(NUCLEUS_REPO_ROOT="$PWD" "$_script_path" logs 2>&1 || true)  # check-suppress:suppression_doc: test probe
        _svc_logs_output=$(echo "$_svc_logs_output" | grep -v '^svc: warning:' || true)  # check-suppress:suppression_doc: strip warning
        if echo "$_svc_logs_output" | grep -q "capture=all"; then
          assert_pass "svc logs: listing shows capture=all"
        else
          assert_fail "svc logs: listing shows capture=all" "No capture=all found in logs listing"
        fi
        for _expected_svc in caddy jellyfin litellm ollama sshd; do
          if echo "$_svc_logs_output" | grep -qE "^\s+$_expected_svc\s"; then
            assert_pass "svc logs: service $_expected_svc listed"
          else
            assert_fail "svc logs: service $_expected_svc listed" "Missing from listing"
          fi
        done
        ;;

      *)
        echo "WARNING: unknown script '$_script_path'"
        ;;
    esac
  ) > "$_out_file" 2>&1
}

# Parallel execution: launch workers with PID cap
_ALL_SCRIPTS=(
  scripts/vm.sh
  src/scripts/apply.sh
  scripts/bootstrap.sh
  scripts/health-check.sh
  scripts/update.sh
  scripts/ai.sh
  scripts/cloud-setup.sh
  scripts/gc.sh
  scripts/gc.ps1
  src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1
  scripts/replica-reset.sh
  scripts/replica-sync.sh
  scripts/check-sh.sh
  scripts/check.sh
  scripts/gs-pdf-opt.sh
  src/scripts/services/camilladsp-daemon.sh
  src/scripts/services/camilladsp-heartbeat.sh
  scripts/svc.sh
  src/scripts/services/service-watchdog.sh
  src/scripts/services/service-watchdog.ps1
  src/hosts/Windows/modules/system/Sync-TerminalActivation.ps1
  tests/scripts/terminal-activations-tests.sh
  tests/hosts/Windows/system/Sync-TerminalActivation.Tests.ps1
)

_PIDS=()
_WORKER_ID=0
for _SCRIPT in "${_ALL_SCRIPTS[@]}"; do
  _run_script_worker "$_SCRIPT" "$_WORKER_ID" &
  _PIDS+=($!)
  _WORKER_ID=$((_WORKER_ID + 1))
  if [[ ${#_PIDS[@]} -ge $PARALLEL_JOBS ]]; then
    wait "${_PIDS[@]}"
    _PIDS=()
  fi
done
wait

# Aggregate results from worker output files
TESTS_PASSED=0
TESTS_FAILED=0
for _out_file in "$_TEST_TMPDIR"/worker_*.out; do
  [[ -f "$_out_file" ]] || continue
  cat "$_out_file"
  while IFS= read -r _line; do
    # Strip ANSI escape sequences for accurate pattern matching
    _clean_line=$(printf '%s' "$_line" | sed 's/\x1b\[[0-9;]*m//g')
    if [[ "$_clean_line" == ✓* ]]; then ((++TESTS_PASSED)); fi
    if [[ "$_clean_line" == ✗* ]]; then ((++TESTS_FAILED)); fi
  done < "$_out_file"
done

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

# Summary

echo ""
echo "============================================================"
echo "Test Summary:"
# shellcheck disable=SC2031 # reason: GREEN is a constant (set in test-lib.sh), not modified in subshell
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
# shellcheck disable=SC2031 # reason: RED is a constant (set in test-lib.sh), not modified in subshell
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
