#!/usr/bin/env bash
# Runs the full repository test suite in sequence.
#
# Test suites (1-5):
#
# Code quality tests (2-3):
#   2. Shell script linting (treefmt)
#   3. PowerShell lint (PSScriptAnalyzer) and Phase 1b cache tests and Phase 1b cache tests
#
# Functional tests (1, 4-5):
#   1. Nix test suite — auto-discover and run all *.nix test files
#   4. Nucleus apps smoke tests (build + --help / dry-run)
#   5. System config build (build all host system derivations)
#
# Mode taxonomy:
#   No --scoped/--full distinction (all steps run by default). Use
#   --skip-system-build to skip step 5. Use --quiet to suppress non-error
#   output across all applicable steps (failures always shown).
#
# Output conventions:
#   Warnings (warn) and errors (error) go to stderr; info/success/skip
#   (say) go to stdout. This differs from test.ps1, which routes all
#   output to stdout. The split is intentional per platform convention.
#   Use test.ps1's header comment as the cross-reference source of truth
#   for the Windows-side convention.
#
# Dependencies policy:
# Every external tool required by any step in this script MUST be declared in
# the pre-flight block below. Missing tools cause an immediate hard failure —
# steps MUST NEVER silently skip due to missing dependencies.
# The pre-flight block is the single source of truth for all tool requirements.
# To add a new tool-using step, first add it to pre-flight, then provision it
# on all target hosts (core.nix for POSIX).
#
# File discovery policy:
# Test file discovery is dynamic — the script finds all *.nix files under
# tests/ automatically via `find tests -name '*.nix'`. Adding a new test
# directory does NOT require editing this script.
#
# Arguments:
#   -q|--quiet           Suppress success/progress output across applicable steps.
#                        Step 1: suppresses PASS/Testing lines from Nix test suite.
#                        Steps 2-3: naturally quiet (only output on failure).
#                        Step 4: suppresses progress messages from smoke tests.
#                        Step 5: suppresses build output on success.
#   --fail-fast          Exit immediately on first failure (default).
#   --no-fail-fast       Accumulate all failures.
#   --skip-system-build  Skip building the host system configuration.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Prerequisites:
#   - nix, nix-instantiate (for Nix test suite)
#   - treefmt (for shell linting)
#   - pwsh (for PowerShell lint)
#   - bash, find, xargs (for test discovery and execution)
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
#   Intentionally omits -e: errors accumulate via exit_code variable.
# By default, FAIL_FAST=true (exit immediately on first failure).
# Use --no-fail-fast to accumulate all failures.
set -uo pipefail
exit_code=0
FAIL_FAST=true

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)
# shellcheck source=../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

usage() {
  usage_std "test.sh" "[-q|--quiet] [--fail-fast|--no-fail-fast] [--skip-system-build]" "Run the repository test suite. With --quiet, suppress success/progress output across applicable steps (failures always shown). By default, all output is shown. --fail-fast exits immediately on first failure (default); --no-fail-fast accumulates all failures. --skip-system-build skips building the system configuration."
}

# Flags
quiet_mode=false
skip_system_build=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|--quiet) quiet_mode=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --no-fail-fast) FAIL_FAST=false; shift ;;
    --fail-fast) FAIL_FAST=true; shift ;;
    --skip-system-build) skip_system_build=true; shift ;;
    --) shift; break ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *) break ;;
  esac
done

# No positional arguments accepted.
if [ "$#" -gt 0 ]; then
  error "unexpected argument '$1'"
  usage >&2
  exit 1
fi

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run nucleus-apply to install them, or use
# nix run .#test to run via the flake wrapper which bundles all deps.
require_command nix
require_command nix-instantiate
require_command treefmt
require_command pwsh
require_command bash
require_command find
require_command xargs

_step=0
# Cache test file list — used in both quiet and normal branches to avoid redundant find.
TEST_NIX_FILES=$(find tests -name '*.nix' -type f ! -name 'lib.nix' | sort)
readarray -t TEST_NIX_FILES_ARR <<< "$TEST_NIX_FILES"

# Wave parallelism infrastructure: each step writes its exit code to a per-step temp file.
# Results are aggregated at the end. In FAIL_FAST mode, steps run sequentially (original behavior).
_wave_tmpdir=$(mktemp -d) || { error "failed to create wave temp directory"; exit 1; }
trap 'rm -rf -- "$_wave_tmpdir"' EXIT

# 1. Nix test suite — auto-discover and run all *.nix test files
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Nix test suite"
{
tmp_failed=$(mktemp) || { error "failed to create temp file"; }
if [ "$quiet_mode" = true ]; then
  # Quiet: suppress Testing: / PASS: lines and nix output on success.
  # Use cached test file list.
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in sh -c
  printf '%s\0' "${TEST_NIX_FILES_ARR[@]}" \
    | xargs -P "$PARALLEL_JOBS" -I{} sh -c '
        f="$1"; tmp="$2"
        if out=$(nix-instantiate --eval --strict "$f" 2>&1); then
          true
        else
          echo "FAIL: $f" >&2
          echo "$f" >> "$tmp"
          echo "$out" >&2
        fi
      ' _ {} "$tmp_failed"
else
  # Normal: show Testing: / PASS: lines and nix output for all tests.
  # Use cached test file list.
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in sh -c
  printf '%s\0' "${TEST_NIX_FILES_ARR[@]}" \
    | xargs -P "$PARALLEL_JOBS" -I{} sh -c 'f="$1"; echo "Testing: $f" >&2; if ! nix-instantiate --eval --strict "$f"; then echo "FAIL: $f" >&2; echo "$f" >> "$2"; else echo "PASS: $f" >&2; fi' _ {} "$tmp_failed"
fi
if [ -s "$tmp_failed" ]; then
  error "FAILED Nix tests:"
  cat "$tmp_failed" >&2
  rm -f "$tmp_failed"
  echo "1" > "$_wave_tmpdir/step-1.exit"
fi
rm -f "$tmp_failed"
say "all Nix tests passed."
[ -f "$_wave_tmpdir/step-1.exit" ] || echo "0" > "$_wave_tmpdir/step-1.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} &

# 2. Shell script linting (treefmt)
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Shell script linting (treefmt)"
{
bash scripts/check-sh.sh || echo "1" > "$_wave_tmpdir/step-2.exit"
[ -f "$_wave_tmpdir/step-2.exit" ] || echo "0" > "$_wave_tmpdir/step-2.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} &

# 3. PowerShell lint (PSScriptAnalyzer) + cache pre-population tests
_step_start=$(date +%s%3N)
section "$((_step += 1))" "PowerShell lint"
{
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 || echo "1" > "$_wave_tmpdir/step-3.exit"
bash tests/scripts/check-pwsh-cache-tests.sh || echo "1" > "$_wave_tmpdir/step-3.exit"
[ -f "$_wave_tmpdir/step-3.exit" ] || echo "0" > "$_wave_tmpdir/step-3.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} &

# 4. Nucleus apps smoke tests (build + --help / dry-run)
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Nucleus apps smoke tests"
{
if [ "$quiet_mode" = true ]; then
  bash tests/scripts/nucleus-apps-smoke-tests.sh >/dev/null || echo "1" > "$_wave_tmpdir/step-4.exit"
else
  bash tests/scripts/nucleus-apps-smoke-tests.sh || echo "1" > "$_wave_tmpdir/step-4.exit"
fi
[ -f "$_wave_tmpdir/step-4.exit" ] || echo "0" > "$_wave_tmpdir/step-4.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} &

# 5. System config build — build all derivations in the host system config.
# WHY soft-fail: building derivations is slow and network-dependent. Always
# accumulates exit code regardless of FAIL_FAST. Use --skip-system-build to
# skip this step entirely.
_step_start=$(date +%s%3N)
section "$((_step += 1))" "System config build"
if [ "$skip_system_build" = true ]; then
  say "skipping (--skip-system-build)."
else
  case "$(uname)" in
    Darwin) attr="darwinConfigurations.macbook.system" ;;
    Linux)
      if [ -d /etc/nixos ]; then
        attr="nixosConfigurations.nixos.config.system.build.toplevel"
      else
        attr="homeConfigurations.polyipseity.activationPackage"
      fi
      ;;
    *)
      say "system config build: unsupported OS ($(uname)), skipping."
      skip_system_build=true
      ;;
  esac
  if [ "$skip_system_build" != true ]; then
    if [ "$quiet_mode" = true ]; then
      nix build --no-link --keep-going --print-out-paths "./src#$attr" >/dev/null || exit_code=$?
    else
      nix build --no-link --keep-going --print-out-paths "./src#$attr" || exit_code=$?
    fi
  fi
fi
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"

# Wait for all background steps to complete before aggregating
wait

# Wave result aggregation — collect step exit codes from temp files
for _s in 1 2 3 4; do
  _exit_file="$_wave_tmpdir/step-$_s.exit"
  if [ -f "$_exit_file" ]; then
    read -r _code < "$_exit_file"
    if [ "$_code" != "0" ]; then
      exit_code=1
      "$FAIL_FAST" && exit $exit_code
    fi
  fi
done

# Timing summary
say "test step timing:"
_total_ms=0
for _s in 1 2 3 4 5; do
  _time_file="$_wave_tmpdir/step-$_s.time"
  if [ -f "$_time_file" ]; then
    read -r _ms < "$_time_file"
    _total_ms=$((_total_ms + _ms))
    printf '  step %2d: %5d ms\n' "$_s" "$_ms"
  fi
done
printf '  total:   %5d ms\n' "$_total_ms"

if [ $exit_code -ne 0 ]; then
  warn "some tests failed with exit code $exit_code"
  exit $exit_code
fi
say "all tests passed."
