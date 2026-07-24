#!/usr/bin/env bash
# Fast pre-commit checks. PSScriptAnalyzer (heavy lint) lives in test.sh.
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
#   1. Shell script linting (shellcheck)
#   2. PowerShell syntax validation (parser only, no PSScriptAnalyzer)
#   3. Packer template validation
#
# Nix checks (4-8):
#   4. Dead Nix code detection (deadnix)
#   5. Nix flake evaluation
#   6. Nix formatting check (nixfmt --verify)
#   7. Nix lint check (nixf-tidy)
#   8. Stale Nix build artifact check
#
# Test suites (9-12):
#   9. Shell script validation tests
#  10. CWD-independence tests
#  11. Nix search path tests
#  12. Port utility function tests
#
# Data integrity (13-16):
#  13. Lockfile validation
#  14. Locked DSC validation
#  15. Schema validation (JSON/YAML)
#  16. Service registry validation
#
# Policy/verification (17-22):
#  17. YAML validation and linting (yamllint)
#  18. Package manager usage enforcement
#  19. Undocumented error suppression check
#  20. Online determinism checks (--verify mode only)
#  21. Config method compliance
#  22. Activation script token placeholder in comment check
#
# Mode taxonomy:
#   Always-run (no HAS_ARGS guard — run in both --full and --scoped):
#     - Nix flake evaluation                  (step 5)
#     - Stale Nix build artifact check        (step 8)
#     - All test suites                       (steps 9-12)
#     - Lockfile section validation           (step 13)
#     - Locked DSC validation                 (step 14)
#     - Service registry validation           (step 16)
#     - Package manager usage enforcement     (step 18)
#     - Config method compliance              (step 21)
#   Path-scopable (accept file filtering in both modes):
#     - Shell script linting (shellcheck)     (step 1)
#     - PowerShell syntax validation          (step 2)
#     - Packer template validation            (step 3)
#     - Dead Nix code (deadnix)               (step 4)
#     - Nix formatting/lint                   (steps 6-7)
#     - Schema validation                     (step 15)
#     - YAML validation/linting               (step 17)
#     - Undocumented error suppression        (step 19)
#     - Activation script token placeholder   (step 22)
#
# Output conventions:
#   Warnings (warn) and errors (error) go to stderr; info/success/skip
#   (say) go to stdout. This differs from check.ps1, which routes all
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
# Arguments:
#   --format      Format Nix files in-place (instead of just validating).
#   (paths)       Files to check; passes paths through to sub-checkers and
#                 skips whole-repo checks (deadnix, script validation).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Prerequisites:
#   - check-jsonschema (for schema validation)
#   - deadnix (for dead Nix code detection)
#   - jq, yq (for lockfile/registry/DSC validation)
#   - nix (for flake evaluation)
#   - nixf (for Nix lint via nixf-tidy)
#   - nixfmt (for Nix formatting)
#   - packer (for Packer template validation)
#   - pwsh (for PowerShell syntax validation)
#   - yamllint (for YAML linting)
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
  # For PS1 files, search src/ (check.ps1 is the traditional home) but also scripts/ for completeness.
  readarray -t CACHED_PS1_FILES < <(find . -path ./vendor -prune -false -o -name '*.ps1' -print | sort)
  # Shell files for full-mode suppression check — covers both .sh and .zsh in src/scripts.
  readarray -t CACHED_SH_FILES < <(find src/scripts -type f -name '*.sh' -print | sort)
fi

_step=0

# Pre-flight tool availability checks.
# All tools listed in Prerequisites must be present. Missing tools produce
# an immediate hard failure — run nucleus-apply to install them, or use
# nix run .#check to run via the flake wrapper which bundles all deps.
require_command pwsh
require_command nixfmt
require_command yq
require_command jq
require_command deadnix
require_command nixf-tidy
require_command nix
require_command packer
require_command shellcheck
require_command check-jsonschema
require_command yamllint

# sh_lint — Shell script linting (shellcheck)
section "$((_step += 1))" "Shell script linting (shellcheck)"
_sc_exit=0
if [ "${#SH_FILES[@]}" -gt 0 ]; then
  # Scoped mode: delegate to check-sh.sh with --scoped and paths
  bash scripts/check-sh.sh --scoped "${SH_FILES[@]}" || _sc_exit=$?
elif ! $HAS_ARGS; then
  # Full mode: delegate to check-sh.sh (single source of truth for shellcheck invocation)
  bash scripts/check-sh.sh || _sc_exit=$?
else
  say "skipping (no shell scripts to check)."
fi
if [ $_sc_exit -ne 0 ]; then exit_code=$_sc_exit; fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# powershell_syntax — PowerShell syntax validation (parser only, no PSScriptAnalyzer)
section "$((_step += 1))" "PowerShell syntax validation"
_ps_exit=0
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly -Scoped "${PS1_FILES[@]}" || _ps_exit=$?
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 -SyntaxOnly || _ps_exit=$?
else
  say "skipping (no PowerShell scripts to check)."
fi
if [ $_ps_exit -ne 0 ]; then exit_code=$_ps_exit; fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# packer_validate — Packer template validation
section "$((_step += 1))" "Packer template validation"
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}" || exit_code=$?
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh || exit_code=$?
else
  say "skipping (no Packer templates to check)."
fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# dead_nix — Dead Nix code detection
section "$((_step += 1))" "Dead Nix code"
if [ ${#NIX_FILES[@]} -gt 0 ]; then
  if ! deadnix --fail "${NIX_FILES[@]}"; then
    exit_code=$?
  else
    say "no dead Nix code found."
  fi
  "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
elif ! $HAS_ARGS; then
  if ! deadnix --fail src/; then
    exit_code=$?
  else
    say "no dead Nix code found."
  fi
  "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping deadnix (path-scoped mode)."
fi

# nix_flake_eval — Always-run: Nix flake evaluation
section "$((_step += 1))" "Nix flake evaluation"
sys=$(nix eval --impure --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
if ! nix eval --impure "path:./src#packages.$sys" >/dev/null; then
  exit_code=$?
else
  say "nix flake evaluation passed."
fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# nix_format — Nix formatting (nixfmt)
section "$((_step += 1))" "Nix formatting (nixfmt)"
if [ "${#NIX_FILES[@]}" -gt 0 ]; then
  # Parallelize nixfmt across PARALLEL_JOBS workers, batching files to reduce process overhead.
  if $FORMAT_NIX; then
    if printf '%s\0' "${NIX_FILES[@]}" | xargs -0 -P "$PARALLEL_JOBS" -n 10 nixfmt -s; then
      say "nix formatting applied."
    else
      exit_code=$?
    fi
  else
    if printf '%s\0' "${NIX_FILES[@]}" | xargs -0 -P "$PARALLEL_JOBS" -n 10 nixfmt -s --verify; then
      say "nix formatting OK."
    else
      exit_code=$?
    fi
  fi
  "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping nixfmt (no Nix files to check)."
fi

# nix_lint — Nix lint check (nixf-tidy)
# Parallelizes across PARALLEL_JOBS workers, each worker writes results
# to a per-file temp file for race-free aggregation.
section "$((_step += 1))" "Nix lint (nixf-tidy)"
if [ "${#NIX_FILES[@]}" -gt 0 ]; then
  _nixf_files=("${NIX_FILES[@]}")
elif ! $HAS_ARGS; then
  _nixf_files=("${CACHED_NIX_FILES[@]}")
else
  _nixf_files=()
fi
_nixf_errors=0
if [ "${#_nixf_files[@]}" -gt 0 ]; then
  _nixf_tmpdir=$(mktemp -d) || { error "failed to create temp directory"; _nixf_errors=$((_nixf_errors + 1)); }
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  printf '%s\0' "${_nixf_files[@]}" \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      f="$1"
      tmpdir="$2"
      # Use tr to encode file path as a safe filename component
      safe_name="$(echo "$f" | tr "/" "_")"
      if ! out=$(nixf-tidy < "$f" 2>&1); then
        printf "FAIL\n%s\n" "$f" > "$tmpdir/${safe_name}.nixf"
      elif [ "$(echo "$out" | jq "length" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        printf "ISSUES\n%s\n%s\n" "$f" "$out" > "$tmpdir/${safe_name}.nixf"
      fi
    ' _ {} "$_nixf_tmpdir"
  # Aggregate results from per-worker temp files
  for _nixf_result in "$_nixf_tmpdir"/*.nixf; do
    [ -f "$_nixf_result" ] || continue
    IFS= read -r _nixf_status < "$_nixf_result"
    IFS= read -r _nixf_file_path < "$_nixf_result"
    case "$_nixf_status" in
      FAIL)
        warn "$_nixf_file_path: nixf-tidy failed"
        _nixf_errors=$((_nixf_errors + 1))
        ;;
      ISSUES)
        # Read the jq output (rest of file after first two lines)
        tail -n +3 "$_nixf_result" | jq -r '.[] | "\(.sname): \(.message)"' | while IFS= read -r _nixf_issue; do
          warn "$_nixf_file_path: $_nixf_issue"
        done
        _nixf_errors=$((_nixf_errors + 1))
        ;;
    esac
  done
  [ -n "$_nixf_tmpdir" ] && rm -rf -- "$_nixf_tmpdir"
  if [ "$_nixf_errors" -gt 0 ]; then
    exit_code=1
    "$FAIL_FAST" && exit $exit_code
  else
    say "nixf-tidy lint passed."
  fi
else
  say "skipping nixf-tidy (no Nix files to check)."
fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# stale_nix_artifact — Always-run: Stale Nix build artifact check
section "$((_step += 1))" "Stale Nix build artifact check"
_cnba_output="$("$SCRIPT_DIR/cleanup-nix.sh" --dry-run 2>&1)"
if echo "$_cnba_output" | grep -q "would remove stale Nix build symlink"; then
  warn "stale Nix build artifacts found:"
  echo "$_cnba_output" | while IFS= read -r _cnba_line; do
    warn "  $_cnba_line"
  done
  exit_code=1
else
  say "no stale Nix build artifacts found."
fi
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# shell_validation_test — Always-run: Shell script validation tests
section "$((_step += 1))" "Shell script validation tests"
bash tests/scripts/script-validation-tests.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# cwd_independence_test — Always-run: CWD-independence tests
section "$((_step += 1))" "CWD-independence tests"
bash tests/scripts/cwd-independence-tests.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# nix_search_path_test — Always-run: Nix search path tests
section "$((_step += 1))" "Nix search path tests"
bash tests/scripts/nix-search-path-tests.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# port_util_test — Always-run: Port utility function tests
section "$((_step += 1))" "Port utility function tests"
bash tests/scripts/lib-port-functions-tests.sh || exit_code=$?
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# lockfile_validation — Lockfile validation
section "$((_step += 1))" "Lockfile validation"

# Consistency and overlap checks (always run, even in path-scoped mode):
#  1. lockfile.json must exist.
#  2. No package should appear in multiple package-manager sections.
#     (Ollama is excluded because it uses a nested structure unrelated to
#      package versions.)
_lfpath="src/lockfiles/lockfile.json"
_lf_overlap_issues=0
if [ ! -f "$_lfpath" ]; then
    warn "lockfile.json not found at $_lfpath"
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
    warn "$_lf_overlaps"
    _lf_overlap_issues=$((_lf_overlap_issues + 1))
  fi
fi
if [ "$_lf_overlap_issues" -gt 0 ]; then
  warn "lockfile.json has $_lf_overlap_issues overlapping package(s) across sections"
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
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
  warn "lifecycle-allowlist.json not found at $_lf_al_path"
  _lf_al_errors=$((_lf_al_errors + 1))
else
  _al_is_obj=$(jq -e 'type == "object"' "$_lf_al_path" >/dev/null 2>&1 && echo true || echo false)
  if [ "$_al_is_obj" != "true" ]; then
    warn "lifecycle-allowlist.json must be a JSON object"
    _lf_al_errors=$((_lf_al_errors + 1))
  else
    # Validate each entry has a non-empty justification string.
    _al_invalid=$(jq -r '
      to_entries[] | select((.value | type) != "string" or .value == "") |
      "WARNING: lifecycle-allowlist.json: \"\(.key)\" has empty or non-string justification"' "$_lf_al_path")
    if [ -n "$_al_invalid" ]; then
      warn "$_al_invalid"
      _lf_al_errors=$((_lf_al_errors + 1))
    fi
  fi
fi
if [ "$_lf_al_errors" -gt 0 ]; then
  warn "lifecycle-allowlist.json validation failed with $_lf_al_errors error(s)"
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
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
        warn "$_section: empty or missing section"
        _lf_errors=$((_lf_errors + 1))
        return
      fi
      # Check for placeholder values
      _placeholders=$(jq -r ".[\"$_section\"] | to_entries[] | select(.value == \"\" or .value == \"CHANGEME\" or .value == \"1.0.0\") | .key" "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        warn "$_section has placeholder versions for:"
        warn "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    }

    # Check sections that must be non-empty
    for _section in scoop cargo-binstall bun uv rustup pwsh; do
      _check_section_nonempty "$_section"
    done

    # winget: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.winget | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      warn "winget: missing or invalid section"
      _lf_errors=$((_lf_errors + 1))
    elif jq '.winget | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "winget: empty section (not yet populated)"
    else
      _placeholders=$(jq -r '.winget | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        warn "winget has placeholder versions for:"
        warn "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    fi
    # homebrew: must be non-empty
    if ! jq -e '.homebrew | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      warn "homebrew: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
    fi
    # vscode: must be non-null; warn if empty, validate non-placeholder if non-empty
    if ! jq -e '.vscode | type == "object"' "$_lfpath" >/dev/null 2>&1; then
      warn "vscode: missing or invalid section"
      _lf_errors=$((_lf_errors + 1))
    elif jq '.vscode | length == 0' "$_lfpath" >/dev/null 2>&1; then
      say "vscode: empty section (not yet populated)"
    else
      _placeholders=$(jq -r '.vscode | to_entries[] | select(.value == "" or .value == "CHANGEME" or .value == "1.0.0") | .key' "$_lfpath" 2>/dev/null)
      if [ -n "$_placeholders" ]; then
        warn "vscode has placeholder versions for:"
        warn "  ${_placeholders//$'\n'/$'\n'  }"
        _lf_errors=$((_lf_errors + 1))
      fi
    fi

    # ollama: must have at least one profile with models
    if ! jq -e '.ollama | type == "object" and length > 0' "$_lfpath" >/dev/null 2>&1; then
      warn "ollama: empty or missing section"
      _lf_errors=$((_lf_errors + 1))
    else
      while IFS=$'\t' read -r _profile _idx _name _tag; do
        if [ -z "$_name" ] || [ -z "$_tag" ]; then
          warn "ollama.${_profile}[${_idx}]: missing name or tag"
          _lf_errors=$((_lf_errors + 1))
        fi
      done < <(jq -r '
        .ollama | to_entries[] | .key as $profile |
        (.value // []) | to_entries[] |
        [$profile, (.key | tostring), (.value.name // ""), (.value.tag // "")] |
        @tsv' "$_lfpath")
    fi

    if [ "$_lf_errors" -gt 0 ]; then
      warn "lockfile.json validation failed with $_lf_errors error(s)"
      exit_code=1
      "$FAIL_FAST" && exit $exit_code
    fi
    say "lockfile.json validation passed"
  else
    warn "lockfile.json not found — skipping section validation"
    exit_code=1
    "$FAIL_FAST" && exit $exit_code
  fi

# locked_dsc_validation — Always-run: Locked DSC validation
section "$((_step += 1))" "Locked DSC validation"
# Platform parallel: check.ps1 uses powershell-yaml with normalization helpers (Windows-native equivalent).
_dsc_system_dir="src/hosts/Windows/system"
  _lockfile="src/lockfiles/lockfile.json"
  _lf_errors=0

  # Generate locked DSC in-memory from ALL system DSC files + lockfile.
  # This mirrors check.ps1's behavior — validates version pins across the
  # full system configuration, not just packages.dsc.yml.
  _locked_json=$(yq eval -o=j '.' "$_dsc_system_dir"/*.dsc.yml 2>/dev/null | jq -s --argjson locked "$(jq -c '.winget // {}' "$_lockfile")" '
    { properties: { resources: (map(.properties.resources // []) | add) } } |
    .properties.resources |= [
      .[] | if .resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and ($locked[.settings.id] | length > 0) then
        .settings.version = $locked[.settings.id]
      else
        .
      end
    ]
  ')

  # For each pinned resource, verify version matches lockfile.
  while IFS=$'\t' read -r _id _pinned_ver; do
    _lf_ver=$(jq -r --arg id "$_id" '.winget[$id] // ""' "$_lockfile")
    if [ -z "$_lf_ver" ]; then
      warn "system DSC files: $_id has version $_pinned_ver but no lockfile entry"
      _lf_errors=$((_lf_errors + 1))
    elif [ "$_pinned_ver" != "$_lf_ver" ]; then
      warn "system DSC files: $_id pinned $_pinned_ver but lockfile has $_lf_ver"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(echo "$_locked_json" | jq -r '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.version != null) | [.settings.id, .settings.version] | @tsv')

  # Check for lockfile entries missing version pins in generated output.
  while IFS=$'\t' read -r _id _lf_ver; do
    _pinned=$(echo "$_locked_json" | jq -r --arg id "$_id" '.properties.resources[] | select(.resource == "Microsoft.WinGet.Client/Package" and .settings.source == "winget" and .settings.id == $id) | .settings.version // ""')
    if [ -z "$_pinned" ]; then
      warn "$_id ($_lf_ver) is in lockfile but missing version pin after generation"
      _lf_errors=$((_lf_errors + 1))
    fi
  done < <(jq -r '.winget // {} | to_entries[] | [.key, .value] | @tsv' "$_lockfile")

  if [ "$_lf_errors" -gt 0 ]; then
    warn "locked DSC validation failed with $_lf_errors error(s)"
    exit_code=1
    "$FAIL_FAST" && exit $exit_code
  fi
  say "locked DSC validation passed"

# schema_validation — Schema validation (JSON/YAML) — path-scopable
section "$((_step += 1))" "Schema validation (JSON/YAML)"
_jsonschema_errors=0
if $HAS_ARGS; then
  # Validate only explicitly provided files
  for _sf in "$@"; do
    case "$_sf" in
      *.json)
        _schema=$(jq -r 'if type == "object" then .["$schema"] // "" else "" end' "$_sf" 2>/dev/null)
        if [ -n "$_schema" ]; then
          case "$_schema" in
            http://*|https://*) continue ;;
            ./*|../*) _schemafile="$(cd "$(dirname "$_sf")" && echo "$(pwd)/${_schema#./}")" ;;
            *)        _schemafile="$_schema" ;;
          esac
          check-jsonschema --schemafile "$_schemafile" "$_sf" 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
        fi
        ;;
      *.yml|*.yaml)
        # shellcheck disable=SC2016 # reason: .$schema is a yq expression, not shell variable expansion
        _schema=$(yq eval '.$schema // ""' "$_sf" 2>/dev/null)
        if [ -n "$_schema" ]; then
          case "$_schema" in
            ./*|../*) _schemafile="$(cd "$(dirname "$_sf")" && echo "$(pwd)/${_schema#./}")" ;;
            *)        _schemafile="$_schema" ;;
          esac
          check-jsonschema --schemafile "$_schemafile" "$_sf" 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
        fi
        ;;
    esac
  done
else
  # JSON files with inline $schema — auto-discover and validate
  for _json_file in "${CACHED_JSON_FILES[@]}"; do
    _schema=$(jq -r 'if type == "object" then .["$schema"] // "" else "" end' "$_json_file")
    if [ -n "$_schema" ]; then
      case "$_schema" in
        http://*|https://*) continue ;; # skip remote URL schemas — validated by upstream tooling
        ./*|../*) _schemafile="$(cd "$(dirname "$_json_file")" && echo "$(pwd)/${_schema#./}")" ;;
        *)        _schemafile="$_schema" ;;
      esac
      check-jsonschema --schemafile "$_schemafile" "$_json_file" 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
    fi
  done
  # YAML files with inline $schema — auto-discover and validate
  for _yaml_file in "${CACHED_YAML_FILES[@]}"; do
    case "$_yaml_file" in */secrets/*) continue ;; esac
    # shellcheck disable=SC2016 # reason: .$schema is a yq expression, not shell variable expansion
    _schema=$(yq eval '.$schema // ""' "$_yaml_file" 2>/dev/null)
    if [ -n "$_schema" ]; then
      case "$_schema" in
        ./*|../*) _schemafile="$(cd "$(dirname "$_yaml_file")" && echo "$(pwd)/${_schema#./}")" ;;
        *)        _schemafile="$_schema" ;;
      esac
      check-jsonschema --schemafile "$_schemafile" "$_yaml_file" 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
    fi
  done
fi
# GitHub schema validation (complements existing prek hooks — CI enforcement) — always-run
check-jsonschema --builtin-schema vendor.github-workflows .github/workflows/*.yml 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
check-jsonschema --builtin-schema vendor.dependabot .github/dependabot.yml 2>/dev/null || _jsonschema_errors=$((_jsonschema_errors + 1))
if [ "$_jsonschema_errors" -gt 0 ]; then
  warn "schema validation failed with $_jsonschema_errors error(s)"
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
fi
say "schema validation passed."
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# service_registry_validation — Always-run: Service registry validation
section "$((_step += 1))" "Service registry validation"
  _svc_json="src/modules/services.json"
  _svc_errors=0

  if [ ! -f "$_svc_json" ]; then
    warn "services.json not found at $_svc_json"
    _svc_errors=$((_svc_errors + 1))
  else
    # Check each entry has displayName and platforms
    while IFS=$'\t' read -r _name _has_display _has_platforms _platform_count; do
      if [ "$_has_display" != "true" ]; then
        warn "services.json: '$_name' missing displayName"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_has_platforms" != "true" ]; then
        warn "services.json: '$_name' missing platforms"
        _svc_errors=$((_svc_errors + 1))
      fi
      if [ "$_platform_count" -lt 1 ]; then
        warn "services.json: '$_name' has no platform entries"
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
          warn "services.json: '$_name' platform '$_platform' has invalid type '$_type'"
          _svc_errors=$((_svc_errors + 1))
          ;;
      esac
      if [ "$_has_required" != "true" ]; then
        warn "services.json: '$_name' platform '$_platform' missing required fields for type '$_type'"
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
    warn "services.json validation failed with $_svc_errors error(s)"
    exit_code=1
    "$FAIL_FAST" && exit $exit_code
  fi
  # No premature "passed" — verdict is after sub-checks below.

  # Validate user-scoped platform entries have justification.
  # User-scoped means domain=user (macOS launchctl) or scope=user (Linux systemctl).
  while IFS=$'\t' read -r _name _platform _domain_scope _value; do
    if [ "$_domain_scope" = "user" ] && { [ "$_value" = "null" ] || [ -z "$_value" ]; }; then
      warn "services.json: '$_name' platform '$_platform' is user-scoped but missing justification"
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
        warn "$_users_json: user '$_username' references unknown service '$_svc_name'"
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
        warn "$_win_users_json: user '$_username' references unknown service '$_svc_name'"
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
    warn "services.json validation failed with $_svc_errors error(s)"
    exit_code=1
    "$FAIL_FAST" && exit $exit_code
  fi
  say "services.json validation passed"

# yaml_validation_lint — YAML validation and linting (merged single loop)
section "$((_step += 1))" "YAML validation and linting"
_yaml_errors=0
if $HAS_ARGS; then
  for _yf in "$@"; do
    case "$_yf" in
      *.yml|*.yaml) ;;
      *) continue ;;
    esac
    if ! yq eval '.' "$_yf" >/dev/null 2>&1; then
      warn "$_yf: invalid YAML"
      _yaml_errors=$((_yaml_errors + 1))
    fi
    if ! yamllint --strict "$_yf" >/dev/null 2>&1; then
      warn "$_yf: yamllint violations"
      _yaml_errors=$((_yaml_errors + 1))
    fi
  done
else
  for _yaml_file in "${CACHED_YAML_FILES[@]}"; do
    case "$_yaml_file" in */secrets/*) continue ;; esac
    if ! yq eval '.' "$_yaml_file" >/dev/null 2>&1; then
      warn "$_yaml_file: invalid YAML"
      _yaml_errors=$((_yaml_errors + 1))
    fi
    if ! yamllint --strict "$_yaml_file" >/dev/null 2>&1; then
      warn "$_yaml_file: yamllint violations"
      _yaml_errors=$((_yaml_errors + 1))
    fi
  done
fi
if [ "$_yaml_errors" -gt 0 ]; then
  warn "YAML validation/lint failed with $_yaml_errors error(s)"
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
fi
say "YAML validation and linting passed."
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# package_manager_enforcement — Always-run: Package manager usage enforcement
section "$((_step += 1))" "Package manager usage enforcement"
# Ban bare `pip install` and `npm install` — these bypass the lockfile and
# produce non-reproducible environments.  `uv pip install` is allowed (uv
# respects the lockfile).  Exclude self-references and help-text mentions.
_violations=0
if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
     --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
     -E '(^|[^a-z])pip install([^-]|$)' \
     scripts/ src/ tests/ 2>/dev/null \
     | grep -v 'uv pip install' \
     | grep . >/dev/null 2>&1; then
  warn "bare pip install detected (use uv pip install instead)"
  _violations=$((_violations + 1))
fi
if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
     --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
     -E '(^|[^a-z])npm install([^-]|$)' \
     scripts/ src/ tests/ 2>/dev/null \
     | grep . >/dev/null 2>&1; then
  warn "bare npm install detected (use bun or nix instead)"
  _violations=$((_violations + 1))
fi
if [ "$_violations" -gt 0 ]; then
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
fi
say "no package manager violations found."

# suppression_doc — Undocumented error suppression check
section "$((_step += 1))" "Undocumented error suppression"
_undoc_supp_out="$(mktemp)" || { warn "failed to create temp file"; exit_code=1; "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code; }

# _is_suppressed check_id file line
# Returns 0 if the given line (or its preceding line) has a
# # check-suppress:<check_id>: comment.
_is_suppressed() {
  local _check_id="$1" _file="$2" _line="$3"
  # Check the target line
  sed -n "${_line}p" "$_file" | grep -qE "# check-suppress:${_check_id}[\s:]" && return 0
  # Check the preceding line
  [ "$_line" -gt 1 ] && sed -n "$((_line - 1))p" "$_file" | grep -qE "# check-suppress:${_check_id}[\s:]" && return 0
  return 1
}

_check_undoc_supp() {
  local _grep_flags="$1" _pattern="$2" _label="$3"
  shift 3
  [ $# -eq 0 ] && return
  grep -Hrn "$_grep_flags" -- "$_pattern" "$@" 2>/dev/null | while IFS=: read -r _f _ln _rest; do
    # Skip comment-only lines (pattern in a comment, not code)
    [[ "$_rest" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with # undoc-supp: inline (deprecated format)
    case "$_rest" in *'# undoc-supp:'*) continue ;; esac
    # Skip lines with # check-suppress:suppression_doc: inline (new format)
    _is_suppressed "suppression_doc" "$_f" "$_ln" && continue
    # Skip lines with suppression comment on the immediately preceding line
    [ "$_ln" -gt 1 ] && { sed -n "$((_ln - 1))p" "$_f" | grep -qE '# undoc-supp:|# check-suppress:suppression_doc[\s:]' && continue; }
    echo "$_f:$_ln ($_label)"
  done >> "$_undoc_supp_out"
}

if $HAS_ARGS; then
  # Path-scoped mode: check only provided files
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real || true operator.
  [ ${#SH_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '|| true' '|| true' "${SH_FILES[@]}"
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real || true operator.
  [ ${#NIX_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '|| true' '|| true' "${NIX_FILES[@]}"
  # shellcheck disable=SC2016 # reason: PowerShell redirection literal, not shell expansion
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '2>$null' '2>$null' "${PS1_FILES[@]}"
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-F' '-ErrorAction SilentlyContinue' '-ErrorAction SilentlyContinue' "${PS1_FILES[@]}"
  [ ${#PS1_FILES[@]} -gt 0 ] && _check_undoc_supp '-E' 'catch[[:space:]]*\{[[:space:]]*\}' 'empty catch {}' "${PS1_FILES[@]}"
else
  # Full mode: use cached file lists.
  _nix_sh_files=("${CACHED_NIX_FILES[@]}" "${CACHED_SH_FILES[@]}")
  _ps1_files=("${CACHED_PS1_FILES[@]}")
  # check-suppress:suppression_doc: string argument specifying the suppression pattern for the check function, not a real || true operator.
  _check_undoc_supp '-F' '|| true' '|| true' "${_nix_sh_files[@]}"
  # shellcheck disable=SC2016 # reason: PowerShell redirection literal, not shell expansion
  _check_undoc_supp '-F' '2>$null' '2>$null' "${_ps1_files[@]}"
  _check_undoc_supp '-F' '-ErrorAction SilentlyContinue' '-ErrorAction SilentlyContinue' "${_ps1_files[@]}"
  _check_undoc_supp '-E' 'catch[[:space:]]*\{[[:space:]]*\}' 'empty catch {}' "${_ps1_files[@]}"
fi

if [ -s "$_undoc_supp_out" ]; then
  warn "undocumented error suppressions found:"
  sort -u "$_undoc_supp_out" | while IFS= read -r _line; do
    warn "  $_line"
  done
  say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
  exit_code=1
else
  say "no undocumented error suppressions found."
fi
rm -f "$_undoc_supp_out"
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
# online_determinism — Online determinism checks (--verify mode only)
section "$((_step += 1))" "Online determinism checks (--verify)"
if $VERIFY; then
  bash "$SCRIPT_DIR/bump-lockfile.sh" --verify || exit_code=$?
  if [ $exit_code -eq 0 ]; then
    say "online determinism checks passed."
  fi
  "$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code
else
  say "skipping (use --verify to run online determinism checks)."
fi

# config_method_compliance — Always-run: Config method compliance
section "$((_step += 1))" "Config method compliance"
_cfg_dir="src/modules/configs"
_cfg_errors=0

# Single-pass: collect all config file basenames, run one grep across src/
_cfg_patterns=$(mktemp) || { warn "failed to create temp file"; exit_code=1; "$FAIL_FAST" && exit $exit_code; }
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

while IFS= read -r -d '' _cfg_file; do
  _basename=$(basename "$_cfg_file")
  # Skip infrastructure files and Nix modules inside configs/
  case "$_basename" in
    .gitkeep|.gitignore|*.schema.json|qtpass.nix) continue ;;
  esac
  # Skip agent customization files (consumed as a directory via Method 4)
  case "$_cfg_file" in
    src/modules/configs/agents/*) continue ;;
  esac
  _relpath="${_cfg_file#src/modules/configs/}"

  # Check against cached grep output — relative path first, then basename
  _refs_output=$(echo "$_cfg_grep_output" | grep -F "$_relpath" 2>/dev/null || true)  # check-suppress:suppression_doc: grep returns non-zero when no matches
  if [ -z "$_refs_output" ]; then
    _refs_output=$(echo "$_cfg_grep_output" | grep -F "$_basename" 2>/dev/null || true)  # check-suppress:suppression_doc: same
  fi

  _refs_lines=0
  _method_lines=0
  if [ -n "$_refs_output" ]; then
    _refs_lines=$(echo "$_refs_output" | wc -l | tr -d ' ')
    # Count lines with # Method on the matched line or preceding line
    while IFS=: read -r _f _ln _rest; do
      if echo "$_rest" | grep -q '# Method'; then
        _method_lines=$((_method_lines + 1))
      elif [ "$_ln" -gt 1 ] && echo "$_cfg_method_output" | grep -q -F "$_f:$((_ln - 1)):"; then
        _method_lines=$((_method_lines + 1))
      fi
    # check-suppress:suppression_doc: here-string with empty/malformed output should not abort the check.
    done <<< "$_refs_output" 2>/dev/null || true
  fi
  if [ "$_refs_lines" -eq 0 ]; then
    warn "$_relpath: no references found in src/ (excluding configs/) — orphaned config?"
    _cfg_errors=$((_cfg_errors + 1))
  elif [ "$_method_lines" -eq 0 ]; then
    warn "$_relpath: referenced but no '# Method N' comment found on or before reference lines"
    _cfg_errors=$((_cfg_errors + 1))
  fi
done < <(find "$_cfg_dir" -type f -print0)
if [ "$_cfg_errors" -gt 0 ]; then
  warn "config method compliance check failed with $_cfg_errors error(s)"
  exit_code=1
  "$FAIL_FAST" && exit $exit_code
fi
say "config method compliance passed."
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

# activation_token_placeholder — Activation script token placeholder in comment check
section "$((_step += 1))" "Activation script token placeholder in comment check"
_act_temp="$(mktemp)" || { warn "failed to create temp file"; exit_code=1; "$FAIL_FAST" && exit $exit_code; }

if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.sh|*.zsh) grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' "$_f" 2>/dev/null >> "$_act_temp" || true  # check-suppress:suppression_doc: grep returns 1 when no matches found
    esac
  done
else
  while IFS= read -r -d '' _f; do
    grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' "$_f" 2>/dev/null >> "$_act_temp" || true  # check-suppress:suppression_doc: grep returns 1 when no matches found
  done < <(find src/scripts -type f \( -name '*.sh' -o -name '*.zsh' \) -print0)
fi

if [ -s "$_act_temp" ]; then
  warn "token placeholder strings found in script comments:"
  sort -u "$_act_temp" | while IFS= read -r _line; do
    warn "  $_line"
  done
  exit_code=1
else
  say "no token placeholder strings in script comments."
fi
rm -f "$_act_temp"
"$FAIL_FAST" && [ $exit_code -ne 0 ] && exit $exit_code

if [ $exit_code -ne 0 ]; then
  warn "some checks failed with exit code $exit_code"
  exit $exit_code
fi
say "all checks passed."
