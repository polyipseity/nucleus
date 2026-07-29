#!/usr/bin/env bash
# Fast pre-commit checks. PSScriptAnalyzer (slow rules excluded) runs inline.
#
# Runs repository checks in sequence:
#
# Checks are organized into topic groups. Within each group, checks are ordered
# alphabetically by their display name. Exceptions: dependency constraints may
# override alphabetical ordering (e.g., Lockfile validation must precede Locked
# DSC validation). New checks should be inserted at their alphabetical position
# within the appropriate group, respecting any dependency constraints.
#
# Toolchain checks (1-3):
#   1. Code formatting (treefmt)
#   2. PowerShell lint (PSScriptAnalyzer with check settings, slow rules excluded)
#   3. Packer template validation
#
# Nix checks (4-6):
#   4. Nix flake evaluation
#   5. Nix lint check (nixf-tidy)
#   6. Stale Nix build artifact check
#
# Test suites (7-10):
#   7. Shell script validation tests
#   8. CWD-independence tests
#   9. Nix search path tests
#  10. Port utility function tests
#
# Data integrity (11-14):
#  11. Lockfile validation
#  12. Locked DSC validation
#  13. Schema validation (JSON/YAML)
#  14. Service registry validation
#
# Policy/verification (15-20):
#  15. YAML structural validation
#  16. Package manager usage enforcement
#  17. Undocumented error suppression check
#  18. Online determinism checks (--verify mode only)
#  19. Config method compliance
#  20. Activation script token placeholder in comment check
#
# Cross-platform correspondence:
#  POSIX (check.sh step 1 via treefmt)  →  Windows (check.ps1 step 1, individual tools)
#    treefmt wraps:
#      nixfmt                              —   Nix-only; not on Windows
#      deadnix                             —   Nix-only; not on Windows
#      yamllint                            →   yamllint (runs individually on Windows)
#      ShellCheck                          —   POSIX-only; not on Windows
#  On Windows, check.ps1 step 1 runs yamllint individually and uses the suffix
#  "(treefmt equivalent)" as the bidirectional anchor. See scripts/check.ps1 header
#  comment for the full mapping and Windows-side counterpart.
#
# Mode taxonomy:
#   Always-run (no HAS_ARGS guard — run in both --full and --scoped):
#     - Stale Nix build artifact check        (step 6)
#     - All test suites                       (steps 7-10)
#     - Lockfile section validation           (step 11)
#     - Locked DSC validation                 (step 12)
#     - Service registry validation           (step 14)
#     - Package manager usage enforcement     (step 16)
#     - Config method compliance              (step 19)
#   Conditional (skips when no .nix files changed):
#     - Nix flake evaluation                  (step 4)
#   Path-scopable (accept file filtering in both modes):
#     - Code formatting (treefmt)             (step 1)
#     - PowerShell lint          (step 2)
#     - Packer template validation            (step 3)
#     - Nix lint (nixf-tidy)                  (step 5)
#     - Schema validation                     (step 13)
#     - YAML structural validation            (step 15)
#     - Undocumented error suppression        (step 17)
#     - Activation script token placeholder   (step 20)
#
# Output conventions:
#   Three-tier messaging: say() for info/success/skip (stdout),
#   warn() for non-fatal warnings (stderr), error() for failures (stderr).
#   The error function returns 1 but is safe here (no set -e; calls are in
#   brace groups). Exit code is driven by the wave exit-file mechanism, not
#   by the function called. This differs from check.ps1, which routes all
#   output to stdout. The split is intentional per platform convention.
#   Use check.ps1's header comment as the cross-reference source of truth
#   for the Windows-side convention.
#
# Always-run checks execute unconditionally in both modes (no HAS_ARGS guard).
# Path-scopable checks use the provided file arguments to filter their scope.
#
# Dependencies policy:
# Every external tool required by any check in this script MUST be declared in
# the pre-flight block below. Missing tools cause an immediate hard failure —
# checks MUST NEVER silently skip due to missing dependencies.
# The pre-flight block is the single source of truth for all tool requirements.
# To add a new tool-using check, first add it to pre-flight, then provision it
# on all target hosts (core.nix for POSIX, Ensure-Tool for Windows).
#
# File discovery policy:
# All file lists in this script MUST be auto-discovered (find, glob patterns
# that pick up new files automatically). Hard-coded file paths in validation
# steps are not allowed. When adding new checks, implement dynamic discovery.
#
# Timing notes:
#   Step-level timings are measured and reported automatically at the end of
#   each run. Reference timings below were taken on a MacBook (Apple Silicon)
#   while charging. Expect roughly 1.3-1.5× longer on battery (CPU throttling).
#   Windows host timings vary independently — check.ps1 reports its own timing.
#   See the "check results" summary block after each run for current timings.
#
# Arguments:
#   --format      Format Nix files in-place (instead of just validating).
#   (paths)       Files to check; passes paths through to sub-checkers and
#                 skips whole-repo checks (always-run checks that don't support path filtering).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Prerequisites:
#   - check-jsonschema (for schema validation)
#   - jq, yq (for lockfile/registry/DSC validation)
#   - nix (for flake evaluation)
#   - nixf (for Nix lint via nixf-tidy)
#   - packer (for Packer template validation)
#   - pwsh (for PowerShell lint)
#   - treefmt (for code formatting and linting)
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
# By default, all checks run and failures accumulate (report-at-end).
# Use --fail-fast to exit immediately on the first failure.
# Intentionally omits -e: errors accumulate via exit_code variable (report-at-end).
# Use --fail-fast for immediate exit on first failure.
set -uo pipefail

exit_code=0
FAIL_FAST=false

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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# Override say/error/warn/section with step-prefix support for check.sh step blocks.
# section() sets _step_prefix so say/error/warn include [Step N] in output.
# This avoids per-block redefinition across 21 step blocks.
say() { printf '%s\n' "${_step_prefix:+[Step $_step_prefix] }$_nuc_prefix: $*"; }
error() { printf '%s\n' "${_step_prefix:+[Step $_step_prefix] }$_nuc_prefix: error: $*" >&2; return 1; }
warn() { printf '%s\n' "${_step_prefix:+[Step $_step_prefix] }$_nuc_prefix: warning: $*" >&2; }
section() { _step_prefix=$1; printf '\n=== [%s] %s ===\n' "$1" "$2"; }

REPO_ROOT=$(derive_repo_root)
cd "$REPO_ROOT" || exit

FORMAT_NIX=false
VERIFY=false
SCOPED=false
FULL=false

usage() {
  usage_std "check.sh" "[--format] [--fail-fast|--no-fail-fast] [--scoped|--full] [--verify] [path ...]" "Run all repository validation checks in sequence. Use --scoped to skip whole-repo checks (path-scoped mode), --full to force whole-repo checks even with paths. Default: scoped if paths given, full otherwise. With arguments, passes paths through to supporting checkers. Use --format to enable in-place Nix formatting. Use --fail-fast to exit immediately on first failure (default: accumulate all). Use --no-fail-fast to accumulate all failures (default). Use --verify to additionally run online determinism checks (requires network)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --format)
      FORMAT_NIX=true
      shift
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    --no-fail-fast)
      FAIL_FAST=false
      shift
      ;;
    --scoped)
      SCOPED=true
      shift
      ;;
    --full)
      FULL=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    -*)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# Validate mutual exclusivity: --scoped and --full cannot be combined.
if "$SCOPED" && "$FULL"; then
  error "cannot specify both --scoped and --full"
  usage >&2
  exit 1
fi

# Determine HAS_ARGS based on paths and mode flags.
HAS_ARGS=false
[ "$#" -gt 0 ] && HAS_ARGS=true
if $SCOPED; then
  HAS_ARGS=true
fi
if $FULL; then
  HAS_ARGS=false
fi

# When paths are provided, group them by extension so each sub-checker
# receives only the files it understands. This allows prek (or other
# pre-commit tools) to invoke the consolidated check with a combined
# files pattern matching multiple extensions.
SH_FILES=()
PS1_FILES=()
PKR_FILES=()
NIX_FILES=()
if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.sh)      SH_FILES+=("$_f") ;;
      *.ps1)     PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
      *.nix)     NIX_FILES+=("$_f") ;;
    esac
  done
fi

# Cached file lists — used in full mode to avoid repeated find traversals.
# Populated only when no explicit paths provided.
if ! $HAS_ARGS; then
  readarray -t CACHED_NIX_FILES < <(find . -path ./vendor -prune -false -o -name '*.nix' -print | sort)
  readarray -t CACHED_YAML_FILES < <(find . -not -path '*/vendor/*' \( -name '*.yml' -o -name '*.yaml' \) -print | sort)
  readarray -t CACHED_JSON_FILES < <(find src -name '*.json' -not -path '*/vendor/*' -not -name '*.schema.json' -print | sort)
  # Shell files for full-mode suppression check — covers both .sh and .zsh in src/scripts.
  readarray -t CACHED_SH_FILES < <(find src/scripts -type f -name '*.sh' -print | sort)
fi

# Wave parallelism infrastructure: each step writes its exit code to a per-step temp file.
# Results are aggregated at the end. In FAIL_FAST mode, steps run sequentially (original behavior).
_wave_tmpdir=$(mktemp -d) || { error "failed to create wave temp directory"; exit 1; }
trap 'rm -rf -- "$_wave_tmpdir"' EXIT

_step=0

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run nucleus-apply to install them, or use
# nix run .#check to run via the flake wrapper which bundles all deps.
require_command pwsh
require_command treefmt
require_command yq
require_command jq
require_command nixf-tidy
require_command nix
require_command packer
require_command check-jsonschema

# Remove stale result symlinks before any checks run.
# `nix build -o result` and invocations of treefmt wrappers create result
# symlinks that are stale between rebuilds.  Removing them prevents the
# stale-artifact check (step 6) from flagging them mid-run.
# The path is relative to REPO_ROOT which is the cwd at this point.
rm -f result result-*

# code_formatting — Code formatting (treefmt)
# On Windows, this corresponds to check.ps1 step 1 which runs yamllint individually
# (treefmt is not available on Windows). See check.ps1 header comment for the full mapping.
# Uses --fail-on-change instead of --ci to preserve eval cache (mtime-based)
# for faster subsequent runs. --fail-on-change replicates the CI-safe
# exit-code contract (exit 1 = formatting drift) without --no-cache.
# Merged: was steps 1 (shell) + 4 (code), now runs treefmt once for all types.
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Code formatting (treefmt)" > "$_wave_tmpdir/step-$_step.out"
echo "Code formatting (treefmt)" > "$_wave_tmpdir/step-$_step.name"
{
_tf_exit=0
if $HAS_ARGS; then
  if $FORMAT_NIX; then
    treefmt "$@" || _tf_exit=$?
  else
    treefmt --fail-on-change "$@" || _tf_exit=$?
  fi
else
  if $FORMAT_NIX; then
    treefmt || _tf_exit=$?
  else
    treefmt --fail-on-change || _tf_exit=$?
  fi
fi
if [ $_tf_exit -eq 0 ]; then
  say "formatting OK."
elif [ $_tf_exit -eq 1 ]; then
  error "formatting issues found (run 'treefmt' to fix)."
else
  error "treefmt failed with exit code $_tf_exit"
fi
echo "$_tf_exit" > "$_wave_tmpdir/step-1.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# powershell_lint — PowerShell lint (PSScriptAnalyzer with check settings)
_step_start=$(date +%s%3N)
section "$((_step += 1))" "PowerShell lint" > "$_wave_tmpdir/step-$_step.out"
echo "PowerShell lint" > "$_wave_tmpdir/step-$_step.name"
{
_ps_exit=0
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  # Use -Command (not -File) because -File mode can't bind array/remaining-arguments params.
  # Build a PowerShell array literal for the paths and pass via -Command.
  _ps_paths=$(printf "'%s'," "${PS1_FILES[@]}")
  pwsh -NoLogo -NoProfile -NonInteractive -Command "& scripts/check-pwsh.ps1 -Settings scripts/PSScriptAnalyzerSettings.check.psd1 -Scoped -Paths @(${_ps_paths%,})" || _ps_exit=$?
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -Settings scripts/PSScriptAnalyzerSettings.check.psd1 || _ps_exit=$?
else
  say "skipping (no PowerShell scripts to check)."
fi
echo "$_ps_exit" > "$_wave_tmpdir/step-2.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# packer_validate — Packer template validation
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Packer template validation" > "$_wave_tmpdir/step-$_step.out"
echo "Packer template validation" > "$_wave_tmpdir/step-$_step.name"
{
_pkr_exit=0
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}" || _pkr_exit=$?
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh || _pkr_exit=$?
else
  say "skipping (no Packer templates to check)."
fi
echo "$_pkr_exit" > "$_wave_tmpdir/step-3.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &



# nix_flake_eval — Nix flake evaluation (conditional skip: only when .nix files changed)
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Nix flake evaluation" > "$_wave_tmpdir/step-$_step.out"
echo "Nix flake evaluation" > "$_wave_tmpdir/step-$_step.name"
{
_nix_eval_nix_files=()
if $HAS_ARGS; then
  # Scoped mode: check if any .nix files are in scope
  _nix_eval_nix_files=("${NIX_FILES[@]+${NIX_FILES[@]}}")
else
  # Full mode: check for .nix files changed from HEAD (tracked + untracked)
  if command -v git >/dev/null 2>&1; then
    while IFS= read -r _f; do
      _nix_eval_nix_files+=("$_f")
    done < <({ git diff --name-only HEAD -- '*.nix' 2>/dev/null || true; git ls-files --others --exclude-standard '*.nix' 2>/dev/null || true; } | sort -u || true) # check-suppress:suppression_doc: all three may fail (no HEAD in shallow clone, git ls-files on uninitialized repo, sort on empty input)
  fi
fi
_ne_exit=0
if [ "${#_nix_eval_nix_files[@]}" -gt 0 ]; then
  sys=$(nix eval --impure --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
  if ! nix eval --impure "path:./src#packages.$sys" >/dev/null; then
    _ne_exit=1
  else
    say "nix flake evaluation passed."
  fi
else
  say "skipping (no Nix files changed since HEAD)."
fi
echo "$_ne_exit" > "$_wave_tmpdir/step-4.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# nix_lint — Nix lint check (nixf-tidy)
# Parallelizes across PARALLEL_JOBS workers, each worker writes results
# to a per-file temp file for race-free aggregation.
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Nix lint (nixf-tidy)" > "$_wave_tmpdir/step-$_step.out"
echo "Nix lint (nixf-tidy)" > "$_wave_tmpdir/step-$_step.name"
{
if [ "${#NIX_FILES[@]}" -gt 0 ]; then
  _nixf_files=("${NIX_FILES[@]}")
elif ! $HAS_ARGS; then
  _nixf_files=("${CACHED_NIX_FILES[@]}")
else
  _nixf_files=()
fi
_nixf_exit=0
if [ "${#_nixf_files[@]}" -gt 0 ]; then
  _nixf_tmpdir=$(mktemp -d) || { error "failed to create temp directory"; _nixf_exit=$((_nixf_exit + 1)); }
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "${_nixf_files[@]}" \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      tmpdir="$1"
      f="$2"
      # Use tr to encode file path as a safe filename component
      safe_name="$(echo "$f" | tr "/" "_")"
      if ! out=$(nixf-tidy < "$f" 2>&1); then
        printf "FAIL\n%s\n" "$f" > "$tmpdir/${safe_name}.nixf"
      elif [ "$(echo "$out" | jq "length" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        printf "ISSUES\n%s\n%s\n" "$f" "$out" > "$tmpdir/${safe_name}.nixf"
      fi
    ' _ "$_nixf_tmpdir"
  # Aggregate results from per-worker temp files
  for _nixf_result in "$_nixf_tmpdir"/*.nixf; do
    [ -f "$_nixf_result" ] || continue
    IFS= read -r _nixf_status < "$_nixf_result"
    IFS= read -r _nixf_file_path < "$_nixf_result"
    case "$_nixf_status" in
      FAIL)
        error "$_nixf_file_path: nixf-tidy failed"
        _nixf_exit=$((_nixf_exit + 1))
        ;;
      ISSUES)
        # Read the jq output (rest of file after first two lines)
        tail -n +3 "$_nixf_result" | jq -r '.[] | "\(.sname): \(.message)"' | while IFS= read -r _nixf_issue; do
          error "$_nixf_file_path: $_nixf_issue"
        done
        _nixf_exit=$((_nixf_exit + 1))
        ;;
    esac
  done
  [ -n "$_nixf_tmpdir" ] && rm -rf -- "$_nixf_tmpdir"
fi
if [ "$_nixf_exit" -gt 0 ]; then
  echo "1" > "$_wave_tmpdir/step-5.exit"
else
  say "nixf-tidy lint passed."
  echo "0" > "$_wave_tmpdir/step-5.exit"
fi
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# stale_nix_artifact — Always-run: Stale Nix build artifact check
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Stale Nix build artifact check" > "$_wave_tmpdir/step-$_step.out"
echo "Stale Nix build artifact check" > "$_wave_tmpdir/step-$_step.name"
{
_cnba_output="$("$SCRIPT_DIR/cleanup-nix.sh" --dry-run 2>&1)"
if echo "$_cnba_output" | grep -q "would remove stale Nix build symlink"; then
  error "stale Nix build artifacts found:"
  echo "$_cnba_output" | while IFS= read -r _cnba_line; do
    error "  $_cnba_line"
  done
  echo "1" > "$_wave_tmpdir/step-6.exit"
else
  say "no stale Nix build artifacts found."
  echo "0" > "$_wave_tmpdir/step-6.exit"
fi
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# shell_validation_test — Always-run: Shell script validation tests
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Shell script validation tests" > "$_wave_tmpdir/step-$_step.out"
echo "Shell script validation tests" > "$_wave_tmpdir/step-$_step.name"
{
_svt_exit=0
echo "--- test output ---"
bash tests/scripts/script-validation-tests.sh || _svt_exit=$?
echo "--- end test output ---"
echo "--- test output ---"
bash tests/scripts/check-output-format-tests.sh || _svt_exit=$?
echo "--- end test output ---"
echo "$_svt_exit" > "$_wave_tmpdir/step-7.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# cwd_independence_test — Always-run: CWD-independence tests
_step_start=$(date +%s%3N)
section "$((_step += 1))" "CWD-independence tests" > "$_wave_tmpdir/step-$_step.out"
echo "CWD-independence tests" > "$_wave_tmpdir/step-$_step.name"
{
_cit_exit=0
echo "--- test output ---"
bash tests/scripts/cwd-independence-tests.sh || _cit_exit=$?
echo "--- end test output ---"
echo "$_cit_exit" > "$_wave_tmpdir/step-8.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# nix_search_path_test — Always-run: Nix search path tests
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Nix search path tests" > "$_wave_tmpdir/step-$_step.out"
echo "Nix search path tests" > "$_wave_tmpdir/step-$_step.name"
{
_nspt_exit=0
echo "--- test output ---"
bash tests/scripts/nix-search-path-tests.sh || _nspt_exit=$?
echo "--- end test output ---"
echo "$_nspt_exit" > "$_wave_tmpdir/step-9.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# port_util_test — Always-run: Port utility function tests
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Port utility function tests" > "$_wave_tmpdir/step-$_step.out"
echo "Port utility function tests" > "$_wave_tmpdir/step-$_step.name"
{
_put_exit=0
echo "--- test output ---"
bash tests/scripts/lib-port-functions-tests.sh || _put_exit=$?
echo "--- end test output ---"
echo "$_put_exit" > "$_wave_tmpdir/step-10.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# lockfile_validation — Lockfile validation
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Lockfile validation" > "$_wave_tmpdir/step-$_step.out"
echo "Lockfile validation" > "$_wave_tmpdir/step-$_step.name"
{
# Consistency and overlap checks (always run, even in path-scoped mode):
#  1. lockfile.json must exist.
#  2. No package should appear in multiple package-manager sections.
#     (Ollama is excluded because it uses a nested structure unrelated to
#      package versions.)
_lfpath="src/lockfiles/lockfile.json"
_lf_overlap_issues=0
if [ ! -f "$_lfpath" ]; then
    error "lockfile.json not found at $_lfpath"
  _lf_overlap_issues=$((_lf_overlap_issues + 1))
  # Do not exit early — the section below may still run useful checks if
  # HAS_ARGS is false; the error count will cause a non-zero exit later.
else
  # Known cross-section overlaps that are legitimate (same publisher.package ID
  # used for different products across package-manager sections).
  # Add new entries here with a brief justification comment.
  # astral-sh.ty: VS Code extension (vscode) vs CLI tool (winget) — different products
  _lf_overlap_exceptions='["astral-sh.ty"]'
  _lf_overlaps=$(jq -r --argjson exceptions "$_lf_overlap_exceptions" '
    [to_entries[] | select(.key != "ollama" and (.value | type == "object")) | .key as $s | (.value | keys)[] | {s: $s, p: .}]
    | group_by(.p)
    | map(select(length > 1))
    | .[][]
    | select(.p as $p | ($exceptions | index($p)) | not)
    | "ERROR: package \"\(.p)\" appears in both \(.s)"' "$_lfpath" 2>/dev/null)
  if [ -n "$_lf_overlaps" ]; then
    error "$_lf_overlaps"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  fi
fi
if [ "$_lf_overlap_issues" -gt 0 ]; then
  error "lockfile.json has $_lf_overlap_issues overlapping package(s) across sections"
  echo "1" > "$_wave_tmpdir/step-11.exit"
else
  say "lockfile.json consistency: no overlapping packages across sections"
fi

# Lifecycle script allowlist validation (always run):
#  - lifecycle-allowlist.json must exist and be a valid JSON object.
#  - Each entry must have a non-empty justification string.
#  - The allowlist starts empty — this provides the mechanism for future
#    per-package lifecycle script approval.
_lf_al_path="src/lockfiles/lifecycle-allowlist.json"
_lf_al_errors=0
if [ ! -f "$_lf_al_path" ]; then
  error "lifecycle-allowlist.json not found at $_lf_al_path"
  _lf_al_errors=$((_lf_al_errors + 1))
else
  _al_is_obj=$(jq -e 'type == "object"' "$_lf_al_path" >/dev/null 2>&1 && echo true || echo false)
  if [ "$_al_is_obj" != "true" ]; then
    error "lifecycle-allowlist.json must be a JSON object"
    _lf_al_errors=$((_lf_al_errors + 1))
  else
    # Validate each entry has a non-empty justification string.
    _al_invalid=$(jq -r '
      to_entries[] | select((.value | type) != "string" or .value == "") |
      "WARNING: lifecycle-allowlist.json: \"\(.key)\" has empty or non-string justification"' "$_lf_al_path")
    if [ -n "$_al_invalid" ]; then
      error "$_al_invalid"
      _lf_al_errors=$((_lf_al_errors + 1))
    fi
  fi
fi
if [ "$_lf_al_errors" -gt 0 ]; then
  error "lifecycle-allowlist.json validation failed with $_lf_al_errors error(s)"
  echo "1" > "$_wave_tmpdir/step-11.exit"
else
  _lf_al_count=$(jq 'length' "$_lf_al_path" 2>/dev/null || echo 0)
  say "lifecycle-allowlist.json: valid (entry count: $_lf_al_count)"
fi

# Always-run: Lockfile section validation
if [ -f "$_lfpath" ]; then
    _lf_errors=0

    # Helper: check a section is non-null, non-empty, and has no placeholder values.
    _check_section_nonempty() {
      _section="$1"
      if ! jq -e ".[\"$_section\"] | type == \"object\" and length > 0" "$_lfpath" >/dev/null 2>&1; then
        error "$_section: empty or missing section"
        _lf_errors=$((_lf_errors + 1))
        return
      fi
      # Check for placeholder values
      _placeholders=$(jq -r ".[\"$_section\"] | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "$_section has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    }

    # Check sections that must be non-empty
    for _section in scoop cargo-binstall bun uv rustup pwsh; do
      _check_section_nonempty "$_section"
    done

    # winget: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.winget | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      error "winget: missing or invalid section"
      _lf_errors=$((_lf_errors + 1))
    elif jq '.winget | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "winget: empty section (not yet populated)"
    else
      _placeholders=$(jq -r '.winget | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "winget has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    fi
    # homebrew: must be non-empty
    if ! jq -e '.homebrew | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      error "homebrew: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
    fi
    # vscode: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.vscode | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      error "vscode: missing or invalid section"
      _lf_errors=$((_lf_errors + 1))
    elif jq '.vscode | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "vscode: empty section (not yet populated)"
    else
      _placeholders=$(jq -r '.vscode | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        error "vscode has placeholder versions for:"
        error "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    fi

    # ollama: must have at least one profile with models
    if ! jq -e '.ollama | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      error "ollama: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
    else
      while IFS=$'\t' read -r _profile _idx _name _tag; do
        if [ -z "$_name" ] || [ -z "$_tag" ]; then
          error "ollama.${_profile}[${_idx}]: missing name or tag"
          _lf_errors=$((_lf_errors + 1))
        fi
      done < <(jq -r '
        .ollama | to_entries[] | .key as $profile |
        (.value // []) | to_entries[] |
        [$profile, (.key | tostring), (.value.name // ""), (.value.tag // "")] |
        @tsv' "$_lfpath")
    fi

    if [ "$_lf_errors" -gt 0 ]; then
      error "lockfile.json validation failed with $_lf_errors error(s)"
      echo "1" > "$_wave_tmpdir/step-11.exit"
    fi
    say "lockfile.json validation passed"
  else
    error "lockfile.json not found — skipping section validation"
    echo "1" > "$_wave_tmpdir/step-11.exit"
  fi
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-11.exit" ] || echo "0" > "$_wave_tmpdir/step-11.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# locked_dsc_validation — Always-run: Locked DSC validation
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Locked DSC validation" > "$_wave_tmpdir/step-$_step.out"
echo "Locked DSC validation" > "$_wave_tmpdir/step-$_step.name"
{
# Platform parallel: check.ps1 uses powershell-yaml with normalization helpers (Windows-native equivalent).
_dsc_system_dir="src/hosts/Windows/system"
  _lockfile="src/lockfiles/lockfile.json"
  _lf_errors=0

  # Generate locked DSC in-memory from ALL system DSC files + lockfile.
  # This mirrors check.ps1's behavior — validates version pins across the
  # full system configuration, not just packages.dsc.yml.
  _dsc_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _lf_errors=$((_lf_errors + 1)); }
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "$_dsc_system_dir"/*.dsc.yml \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _safe="$(echo "$_f" | tr "/" "_")"
      yq eval -o=j "." "$_f" > "$_tmpdir/${_safe}.json" 2>/dev/null || rm -f "$_tmpdir/${_safe}.json"
    ' _ "$_dsc_par_tmpdir"
  # Serial merge of parallel results
  if [ -n "$(find "$_dsc_par_tmpdir" -name '*.json' -print 2>/dev/null | head -1)" ]; then
    _locked_json=$(jq -s --argjson locked "$(jq -c '.winget // {}' "$_lockfile")" '
      { properties: { resources: (map(.properties.resources // []) | add) } } |
      .properties.resources |= [
        .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
          .settings.version = $locked[.settings.id]
        else
          .
        end
      ]
    ' "$_dsc_par_tmpdir"/*.json 2>/dev/null)
  else
    _locked_json="{}"
  fi
  rm -rf -- "$_dsc_par_tmpdir"

  # For each pinned resource, verify version matches lockfile.
  while IFS=$'\t' read -r _id _pinned_ver; do
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      error "system DSC files: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      error "system DSC files: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(echo "$_locked_json" | jq -r '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | [.settings.id, .settings.version] | @tsv')

  # Check for lockfile entries missing version pins in generated output.
  while IFS=$'\t' read -r _id _lf_ver; do
    _pinned=$(echo "$_locked_json" | jq -r --arg id "$_id" '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.id == $id) | .settings.version // ""')
    if [ -z "$_pinned" ]; then
      error "$_id ($_lf_ver) is in lockfile but missing version pin after generation"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(jq -r '.winget // {} | to_entries[] | [.key, .value] | @tsv' "$_lockfile")

  if [ "$_lf_errors" -gt 0 ]; then
    error "locked DSC validation failed with $_lf_errors error(s)"
    echo "1" > "$_wave_tmpdir/step-12.exit"
  fi
  say "locked DSC validation passed"
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-12.exit" ] || echo "0" > "$_wave_tmpdir/step-12.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# schema_validation — Schema validation (JSON/YAML) — path-scopable
# Parallelized: groups files by resolved $schema path, dispatches one
# check-jsonschema per schema group via xargs -P "$PARALLEL_JOBS".
# Follows the nixf-tidy parallel pattern (step 6).
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Schema validation (JSON/YAML)" > "$_wave_tmpdir/step-$_step.out"
echo "Schema validation (JSON/YAML)" > "$_wave_tmpdir/step-$_step.name"
{
_jsonschema_errors=0
_js_tmpdir=$(mktemp -d) || { error "failed to create temp directory"; echo "1" > "$_wave_tmpdir/step-13.exit"; }

# Collect file → schema pairs into a temp manifest.
# Format: schemafile<TAB>filepath (one per line)
_js_manifest="$_js_tmpdir/manifest"
if $HAS_ARGS; then
  _js_schema_files=()
  for _sf in "$@"; do
    case "$_sf" in *.json|*.yml|*.yaml) _js_schema_files+=("$_sf") ;; esac
  done
else
  _js_schema_files=("${CACHED_JSON_FILES[@]}")
  for _yf in "${CACHED_YAML_FILES[@]}"; do
    case "$_yf" in */secrets/*) continue ;; esac
    _js_schema_files+=("$_yf")
  done
fi

if [ "${#_js_schema_files[@]}" -gt 0 ]; then
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "${_js_schema_files[@]}" \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _safe="$(echo "$_f" | tr "/" "_")"
      case "$_f" in
        *.json)
          _schema=$(jq -r "if type == \"object\" then .[\"\$schema\"] // \"\" else \"\" end" "$_f" 2>/dev/null)
          ;;
        *.yml|*.yaml)
          _schema=$(yq eval ".\$schema // \"\"" "$_f" 2>/dev/null)
          ;;
      esac
      if [ -n "$_schema" ]; then
        case "$_schema" in
          http://*|https://*) ;; # skip remote URL schemas
          ./*|../*)
            _schemafile="$(cd "$(dirname "$_f")" && echo "$(pwd)/${_schema#./}")"
            printf "%s\t%s\n" "$_schemafile" "$_f" > "$_tmpdir/${_safe}.schema"
            ;;
          *)
            printf "%s\t%s\n" "$_schema" "$_f" > "$_tmpdir/${_safe}.schema"
            ;;
        esac
      fi
    ' _ "$_js_tmpdir"

  # Merge all schema fragments into manifest
  true > "$_js_manifest"
  for _sf in "$_js_tmpdir"/*.schema; do
    [ -f "$_sf" ] && cat "$_sf" >> "$_js_manifest"
  done
fi

# Group by schema and dispatch via xargs -P
if [ -s "$_js_manifest" ]; then
  # Sort by schemafile and group using awk
  # Generates group files: one per unique schema, first line is schemafile,
  # subsequent lines are instance files.
  sort -k1 "$_js_manifest" | awk -F'\t' '
    BEGIN { gid = 0; cur = "" }
    {
      if ($1 != cur) {
        if (cur != "") close(f)
        gid++; cur = $1
        f = "'"$_js_tmpdir"'/g-" gid ".sch"
        print $1 > f
      }
      print $2 >> f
    }
    END { if (cur != "") close(f) }
  '
  # Dispatch each group via xargs -P
  # Each worker reads the batch file (schemafile + instance files), runs
  # check-jsonschema once, writes status to a .st temp file.
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  if [ -n "$(find "$_js_tmpdir" -maxdepth 1 -name 'g-*.sch' -print 2>/dev/null | head -1)" ]; then
    printf '%s\0' "$_js_tmpdir"/g-*.sch \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _tmpdir="$1"
        _batch="$2"
        _schemafile=""
        _files=()
        while IFS= read -r _line; do
          if [ -z "$_schemafile" ]; then
            _schemafile="$_line"
          else
            _files+=("$_line")
          fi
        done < "$_batch"
        _safe="$(echo "$_schemafile" | tr "/" "_")"
        if check-jsonschema --schemafile "$_schemafile" "${_files[@]}" 2>> "$_tmpdir/${_safe}.err"; then
          echo "PASS" > "$_tmpdir/${_safe}.st"
        else
          echo "FAIL" > "$_tmpdir/${_safe}.st"
        fi
      ' _ "$_js_tmpdir"

    # Aggregate results
    for _st_file in "$_js_tmpdir"/*.st; do
      [ -f "$_st_file" ] || continue
      read -r _status < "$_st_file"
      [ "$_status" = "FAIL" ] && _jsonschema_errors=$((_jsonschema_errors + 1))
    done
    # Report per-schema errors
    for _err_file in "$_js_tmpdir"/*.err; do
      [ -s "$_err_file" ] || continue
      while IFS= read -r _line; do
        error "$_line"
      done < "$_err_file"
    done
  fi
fi

# GitHub schema validation — always-run
check-jsonschema --builtin-schema vendor.github-workflows .github/workflows/*.yml || _jsonschema_errors=$((_jsonschema_errors + 1))
check-jsonschema --builtin-schema vendor.dependabot .github/dependabot.yml || _jsonschema_errors=$((_jsonschema_errors + 1))
if [ "$_jsonschema_errors" -gt 0 ]; then
  error "schema validation failed with $_jsonschema_errors error(s)"
  echo "1" > "$_wave_tmpdir/step-13.exit"
fi
say "schema validation passed."
[ -f "$_wave_tmpdir/step-13.exit" ] || echo "0" > "$_wave_tmpdir/step-13.exit"
[ -n "${_js_tmpdir:-}" ] && rm -rf -- "$_js_tmpdir"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# service_registry_validation — Always-run: Service registry validation
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Service registry validation" > "$_wave_tmpdir/step-$_step.out"
echo "Service registry validation" > "$_wave_tmpdir/step-$_step.name"
{
  _svc_json="src/modules/services.json"
  _svc_errors=0

  if [ ! -f "$_svc_json" ]; then
    error "services.json not found at $_svc_json"
    _svc_errors=$((_svc_errors + 1))
  else
    # Check each entry has displayName and platforms
    while IFS=$'\t' read -r _name _has_display _has_platforms _platform_count; do
      if [ "$_has_display" != "true" ]; then
        error "services.json: '$_name' missing displayName"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_has_platforms" != "true" ]; then
        error "services.json: '$_name' missing platforms"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_platform_count" -lt 1 ]; then
        error "services.json: '$_name' has no platform entries"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      [
        .key,
        (.value | has("displayName") and (.displayName | type == "string") and (.displayName | length > 0) | tostring),
        (.value | has("platforms") and (.platforms | type == "object") | tostring),
        (.value.platforms | if type == "object" then (keys | length) else 0 end | tostring)
      ] | @tsv' "$_svc_json")

    # Validate each platform entry has valid type and required fields
    while IFS=$'\t' read -r _name _platform _type _has_required; do
      case "$_type" in
        launchctl|systemctl|native|schtask|omitted) ;;
        *)
          error "services.json: '$_name' platform '$_platform' has invalid type '$_type'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      if [ "$_has_required" != "true" ]; then
        error "services.json: '$_name' platform '$_platform' missing required fields for type '$_type'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
      .key as $name |
      (.value.platforms // {}) | to_entries[] |
      [
        $name,
        .key,
        (.value.type // "missing"),
        (
          if .value.type == "launchctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "systemctl" then (.value.service | type == "string" and length > 0)
          elif .value.type == "native" then (.value.service | type == "string" and length > 0)
          elif .value.type == "schtask" then (.value.taskPath | type == "string" and length > 0)
          elif .value.type == "omitted" then (.value.justification | type == "string" and length > 0)
          else false
          end | tostring
        )
      ] | @tsv' "$_svc_json")
  fi

  if [ "$_svc_errors" -gt 0 ]; then
    error "services.json validation failed with $_svc_errors error(s)"
    echo "1" > "$_wave_tmpdir/step-14.exit"
  fi
  # No premature "passed" — verdict is after sub-checks below.

  # Validate user-scoped platform entries have justification.
  # User-scoped means domain=user (macOS launchctl) or scope=user (Linux systemctl).
  while IFS=$'\t' read -r _name _platform _domain_scope _value; do
    if [ "$_domain_scope" = "user" ] && { [ "$_value" = "null" ] || [ -z "$_value" ]; }; then
      error "services.json: '$_name' platform '$_platform' is user-scoped but missing justification"
      _svc_errors=$((_svc_errors + 1))
    fi
  done < <(jq -r '
    to_entries[] | select(.value | type == "object") | select(.key | startswith("$") | not) |
    .key as $name |
    (.value.platforms // {}) | to_entries[] |
    [
      $name,
      .key,
      (.value.domain // .value.scope // ""),
      (.value.justification | tostring)
    ] | @tsv' "$_svc_json")

  # Validate that service names in users.json services blocks exist in services.json.
  _users_json="src/modules/users.json"
  if [ -f "$_users_json" ]; then
    _svc_names=$(jq -r 'to_entries[].key' "$_svc_json")
    while IFS=$'\t' read -r _username _svc_name _has_enable; do
      if ! echo "$_svc_names" | grep -qxF "$_svc_name"; then
        error "$_users_json: user '$_username' references unknown service '$_svc_name'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
    to_entries[] | select(.key | startswith("$") | not) |
      .key as $user |
      (.value.services // {}) | to_entries[] |
      select(.value.enable != null) |
      [$user, .key, "true"] | @tsv' "$_users_json")
  fi

  # Windows users.json
  _win_users_json="src/hosts/Windows/users.json"
  if [ -f "$_win_users_json" ]; then
    while IFS=$'\t' read -r _username _svc_name _has_enable; do
      if ! echo "$_svc_names" | grep -qxF "$_svc_name"; then
        error "$_win_users_json: user '$_username' references unknown service '$_svc_name'"
        _svc_errors=$((_svc_errors + 1))
      fi
    done < <(jq -r '
      .users // {} | to_entries[] |
      .key as $user |
      (.value.services // {}) | to_entries[] |
      select(.value.enable != null) |
      [$user, .key, "true"] | @tsv' "$_win_users_json")
  fi

  if [ "$_svc_errors" -gt 0 ]; then
    error "services.json validation failed with $_svc_errors error(s)"
    echo "1" > "$_wave_tmpdir/step-14.exit"
  fi
  say "services.json validation passed"
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-14.exit" ] || echo "0" > "$_wave_tmpdir/step-14.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# yaml_structural_validation — YAML structural validation
_step_start=$(date +%s%3N)
section "$((_step += 1))" "YAML structural validation" > "$_wave_tmpdir/step-$_step.out"
echo "YAML structural validation" > "$_wave_tmpdir/step-$_step.name"
{
_yaml_errors=0
_yaml_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _yaml_errors=$((_yaml_errors + 1)); }
# Collect YAML files for validation
_yaml_files=()
if $HAS_ARGS; then
  for _yf in "$@"; do
    case "$_yf" in
      *.yml|*.yaml) _yaml_files+=("$_yf") ;;
    esac
  done
else
  for _yf in "${CACHED_YAML_FILES[@]}"; do
    case "$_yf" in */secrets/*) continue ;; esac
    _yaml_files+=("$_yf")
  done
fi
if [ "${#_yaml_files[@]}" -gt 0 ]; then
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "${_yaml_files[@]}" \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _f="$1"
      _exit=0
      _err=$(yq eval "." "$_f" 2>&1 >/dev/null) || _exit=$?
      if [ "$_exit" -ne 0 ]; then
        printf "invalid_yaml:%s\n" "$_f"
      elif [ -n "$_err" ]; then
        printf "yaml_warn:%s:%s\n" "$_f" "$_err"
      fi
    ' _ 2>/dev/null > "$_yaml_par_tmpdir/yaml_results.txt"
  if [ -s "$_yaml_par_tmpdir/yaml_results.txt" ]; then
    while IFS=: read -r _tag _yf _warn; do
      case "$_tag" in
        invalid_yaml) _yaml_errors=$((_yaml_errors + 1)); error "invalid_yaml:$_yf" ;;
        yaml_warn) error "yaml_warn:$_yf:$_warn" ;;
      esac
    done < "$_yaml_par_tmpdir/yaml_results.txt"
  fi
fi
rm -rf -- "$_yaml_par_tmpdir"
if [ "$_yaml_errors" -gt 0 ]; then
  error "YAML structural validation failed with $_yaml_errors error(s)"
  echo "1" > "$_wave_tmpdir/step-15.exit"
fi
say "YAML structural validation passed."
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-15.exit" ] || echo "0" > "$_wave_tmpdir/step-15.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# package_manager_enforcement — Always-run: Package manager usage enforcement
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Package manager usage enforcement" > "$_wave_tmpdir/step-$_step.out"
echo "Package manager usage enforcement" > "$_wave_tmpdir/step-$_step.name"
{
_violations=0
# Ban bare `pip install` and `npm install` — these bypass the lockfile and
# produce non-reproducible environments.  `uv pip install` is allowed (uv
# respects the lockfile).  Exclude self-references and help-text mentions.
if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
     --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
     -E '(^|[^a-z])pip install([^-]|$)' \
     scripts/ src/ tests/ 2>/dev/null \
     | grep -v 'uv pip install' \
     | grep . >/dev/null 2>&1; then
  error "bare pip install detected (use uv pip install instead)"
  _violations=$((_violations + 1))
fi
if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
     --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
     -E '(^|[^a-z])npm install([^-]|$)' \
     scripts/ src/ tests/ 2>/dev/null \
     | grep . >/dev/null 2>&1; then
  error "bare npm install detected (use bun or nix instead)"
  _violations=$((_violations + 1))
fi
if [ "$_violations" -gt 0 ]; then
  echo "1" > "$_wave_tmpdir/step-16.exit"
fi
say "no package manager violations found."
[ -f "$_wave_tmpdir/step-16.exit" ] || echo "0" > "$_wave_tmpdir/step-16.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# suppression_doc — Undocumented error suppression check
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Undocumented error suppression" > "$_wave_tmpdir/step-$_step.out"
echo "Undocumented error suppression" > "$_wave_tmpdir/step-$_step.name"
{
_s17_errors=0
_step17_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _s17_errors=$((_s17_errors + 1)); }

# Collect script files
_step17_files=()
if $HAS_ARGS; then
  [ ${#SH_FILES[@]} -gt 0 ] && _step17_files+=("${SH_FILES[@]}")
  [ ${#NIX_FILES[@]} -gt 0 ] && _step17_files+=("${NIX_FILES[@]}")
else
  _step17_files=("${CACHED_NIX_FILES[@]}" "${CACHED_SH_FILES[@]}")
fi

if [ "${#_step17_files[@]}" -gt 0 ]; then
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "${_step17_files[@]}" \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _safe="$(echo "$1" | tr "/" "_")"
      _out="$2/${_safe}.out"
      _content=$(<"$1")
      _line_no=0
      while IFS= read -r _line; do
        _line_no=$((_line_no + 1))
        case "$_line" in
          *shellcheck\ disable=*|*check-suppress:*)
            if ! echo "$_line" | grep -q "reason:"; then
              echo "undoc_supp:${1}:${_line_no}:${_line}" >> "$_out"
            fi
            ;;
        esac
      done <<< "$_content"
    ' _ "$_step17_tmpdir"

  # Aggregate errors
  for _f in "$_step17_tmpdir"/*.out; do
    [ -f "$_f" ] || continue
    while IFS= read -r _err; do
      _s17_errors=$((_s17_errors + 1))
      error "$_err"
    done < "$_f"
  done

  if [ "$_s17_errors" -gt 0 ]; then
    say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
    echo "1" > "$_wave_tmpdir/step-17.exit"
  else
    say "no undocumented error suppressions found."
  fi
else
  say "no undocumented error suppressions found."
fi
rm -rf -- "$_step17_tmpdir"
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-17.exit" ] || echo "0" > "$_wave_tmpdir/step-17.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# online_determinism — Online determinism checks (--verify mode only)
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Online determinism checks (--verify)" > "$_wave_tmpdir/step-$_step.out"
echo "Online determinism checks (--verify)" > "$_wave_tmpdir/step-$_step.name"
{
if $VERIFY; then
  bash "$SCRIPT_DIR/bump-lockfile.sh" --verify || exit_code=$?
  if [ $exit_code -eq 0 ]; then
    say "online determinism checks passed."
  fi
  "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping (use --verify to run online determinism checks)."
fi
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} > "$_wave_tmpdir/step-18.out" 2>&1

# config_method_compliance — Always-run: Config method compliance
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Config method compliance" > "$_wave_tmpdir/step-$_step.out"
echo "Config method compliance" > "$_wave_tmpdir/step-$_step.name"
{
_cfg_dir="src/modules/configs"
_cfg_errors=0

# Single-pass: collect all config file basenames, run one grep across src/
_cfg_patterns=$(mktemp) || { error "failed to create temp file"; echo "1" > "$_wave_tmpdir/step-19.exit"; }
find "$_cfg_dir" -type f -exec basename {} \; | sort -u > "$_cfg_patterns"
_cfg_grep_output=$(grep -rn --include='*.nix' --include='*.ps1' --include='*.sh' \
  -F -f "$_cfg_patterns" \
  src/ --exclude-dir='vendor' --exclude-dir='configs' \
  2>/dev/null || true)  # check-suppress:suppression_doc: no matches is valid (no config files referenced in tree)
rm -f "$_cfg_patterns"
_cfg_patterns=

# Single-pass: collect all # Method lines for preceding-line checking
_cfg_method_output=$(grep -rn --include='*.nix' --include='*.ps1' --include='*.sh' \
  '# Method' \
  src/ --exclude-dir='vendor' --exclude-dir='configs' \
  2>/dev/null || true)  # check-suppress:suppression_doc: no matches is valid

_cfg_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _cfg_errors=$((_cfg_errors + 1)); }
# shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
find "$_cfg_dir" -type f -print0 \
  | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
    _tmpdir="$1"
    _f="$2"
    _basename=$(basename "$_f")
    # Skip infrastructure files and Nix modules inside configs/
    case "$_basename" in
      .gitkeep|.gitignore|*.schema.json|qtpass.nix) exit 0 ;;
    esac
    # Skip agent customization files (consumed as a directory via Method 4)
    case "$_f" in
      */configs/agents/*) exit 0 ;;
    esac
    _safe="$(echo "$_f" | tr "/" "_")"
    _result_file="$_tmpdir/${_safe}.result"
    _relpath="${_f#*configs/}"
    # Check for disallowed config methods
    if grep -q "^[^#]*configs\." "$_f" 2>/dev/null; then
      echo "ERROR:$_relpath uses configs. method" >> "$_result_file"
    fi
  ' _ "$_cfg_par_tmpdir"

# Aggregate results
for _result_file in "$_cfg_par_tmpdir"/*.result; do
  [ -f "$_result_file" ] || continue
  while IFS= read -r _eline; do
    case "$_eline" in
      ERROR:*)
        _cfg_errors=$((_cfg_errors + 1))
        error "${_eline#ERROR:}"
        ;;
    esac
  done < "$_result_file"
done
rm -rf -- "$_cfg_par_tmpdir"
if [ "$_cfg_errors" -gt 0 ]; then
  error "config method compliance check failed with $_cfg_errors error(s)"
  echo "1" > "$_wave_tmpdir/step-19.exit"
fi
say "config method compliance passed."
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-19.exit" ] || echo "0" > "$_wave_tmpdir/step-19.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# activation_token_placeholder — Activation script token placeholder in comment check
_step_start=$(date +%s%3N)
section "$((_step += 1))" "Activation script token placeholder in comment check" > "$_wave_tmpdir/step-$_step.out"
echo "Activation script token placeholder in comment check" > "$_wave_tmpdir/step-$_step.name"
{
_act_temp="$(mktemp)" || { error "failed to create temp file"; echo "1" > "$_wave_tmpdir/step-20.exit"; }

if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in *.sh|*.zsh) printf '%s\0' "$_f" ;; esac
  done | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true  # check-suppress:suppression_doc: no matches is valid
else
  find src/scripts -type f \( -name '*.sh' -o -name '*.zsh' \) -print0 \
    | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true  # check-suppress:suppression_doc: no matches is valid
fi

if [ -s "$_act_temp" ]; then
  error "token placeholder strings found in script comments:"
  sort -u "$_act_temp" | while IFS= read -r _line; do
    error "  $_line"
  done
  echo "1" > "$_wave_tmpdir/step-20.exit"
else
  say "no token placeholder strings in script comments."
fi
rm -f "$_act_temp"
# If no exit file was written (all checks passed), write success
[ -f "$_wave_tmpdir/step-20.exit" ] || echo "0" > "$_wave_tmpdir/step-20.exit"
_elapsed=$(($(date +%s%3N) - _step_start))
echo "$_elapsed" > "$_wave_tmpdir/step-$_step.time"
} >> "$_wave_tmpdir/step-$_step.out" 2>&1 &

# Wait for all background steps to complete before aggregating
wait

# Clear step prefix before aggregation output
_step_prefix=''

# Wave result aggregation — collect step exit codes from temp files
say "check results:"
_total_ms=0
_total_steps=20
_failed_steps=""
for _s in $(seq 1 $_total_steps); do
  _exit_file="$_wave_tmpdir/step-$_s.exit"
  _time_file="$_wave_tmpdir/step-$_s.time"
  _name_file="$_wave_tmpdir/step-$_s.name"
  _status="-"
  if [ -f "$_exit_file" ]; then
    read -r _code < "$_exit_file"
    if [ "$_code" != "0" ]; then
      exit_code=1
      _status="✗"
      "$FAIL_FAST" && exit $exit_code
    else
      _status="✓"
    fi
  fi
  if [ -f "$_time_file" ]; then
    read -r _ms < "$_time_file"
    _total_ms=$((_total_ms + _ms))
  else
    _ms=0
  fi
  _name=""
  [ -f "$_name_file" ] && read -r _name < "$_name_file"
  printf '  step %2d  %s  %5d ms  %s\n' "$_s" "$_status" "$_ms" "$_name"
  if [ "$_status" = "✗" ]; then
    _failed_steps="${_failed_steps}step $_s (${_name}), "
  fi
done
printf '  total:   %5d ms\n' "$_total_ms"

  # Replay step output
  for _s in $(seq 1 $_total_steps); do
    _out_file="$_wave_tmpdir/step-$_s.out"
    if [ -f "$_out_file" ]; then
      cat "$_out_file"
    fi
  done

if [ $exit_code -ne 0 ]; then
  error "some checks failed with exit code $exit_code"
  error "Failed steps: ${_failed_steps%, }"
  exit $exit_code
fi
say "all checks passed."
