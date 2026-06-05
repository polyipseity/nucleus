#!/usr/bin/env bash
# check.sh — Consolidated repository validation script.
#
# Runs all repository checks in sequence:
#   1. Nix test suite (tests/nix/*.nix)
#   2. Dead Nix code detection (deadnix)
#   3. Shell script linting (shellcheck)
#   4. PowerShell syntax validation
#   5. Packer template validation
#   6. Shell script validation tests
#
# With arguments, passes them through to individual checkers that support
# path filtering (check-sh.sh, check-pwsh.ps1, check-packer.sh) and skips
# whole-repo checks (Nix tests, deadnix, script validation).
#
# Arguments:
#   (none)        No flags accepted; paths may be provided as positional arguments.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.
set -euo pipefail

# Source shared library when available; fall back to inline helpers for
# standalone execution.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../src/scripts/lib.sh" ]; then
  . "$SCRIPT_DIR/../src/scripts/lib.sh"
else
  # inline usage_std — emit standardized usage text
  usage_std() {
    printf 'usage: %s %s\n' "$1" "${2:-}"
    [ "$#" -gt 2 ] && printf '  %s\n' "$3"
  }
  # inline resolve_nucleus_root (mirrors src/scripts/lib.sh)
  resolve_nucleus_root() {
    if [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ]; then
      printf '%s\n' "$NUCLEUS_REPO_ROOT"
      return 0
    fi
    _rnr_config_file="$HOME/.config/nucleus/repo-root"
    if [ -f "$_rnr_config_file" ]; then
      _rnr_root="$(cat "$_rnr_config_file")"
      if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
        printf '%s\n' "$_rnr_root"
        return 0
      fi
    fi
    if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      if [ -n "$_rnr_git_root" ] && [ -d "$_rnr_git_root" ]; then
        printf '%s\n' "$_rnr_git_root"
        return 0
      fi
    fi
    printf '%s\n' "$HOME/dev/nucleus"
  }
fi

REPO_ROOT=$(resolve_nucleus_root)
cd "$REPO_ROOT"

usage() {
  usage_std "check.sh" "[path ...]" "Run all repository validation checks in sequence. With arguments, passes paths through to supporting checkers and skips whole-repo checks (Nix tests, deadnix, script validation)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf '%s\n' "error: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

HAS_ARGS=false
[ "$#" -gt 0 ] && HAS_ARGS=true

# When paths are provided, group them by extension so each sub-checker
# receives only the files it understands. This allows prek (or other
# pre-commit tools) to invoke the consolidated check with a combined
# files pattern matching multiple extensions.
SH_FILES=()
PS1_FILES=()
PKR_FILES=()
if $HAS_ARGS; then
  for _f in "$@"; do
    case "$_f" in
      *.sh)      SH_FILES+=("$_f") ;;
      *.ps1)     PS1_FILES+=("$_f") ;;
      *.pkr.hcl) PKR_FILES+=("$_f") ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# 1. Nix test suite — auto-discover and run all *.nix test files
# ---------------------------------------------------------------------------
printf '\n=== [1/6] Nix test suite ===\n'
if ! $HAS_ARGS; then
  echo "Running Nix unit tests..."
  FAILED=0
  while IFS= read -r test; do
    echo "Running: $test"
    nix-instantiate --eval "$test" || FAILED=1
  done < <(find tests/nix -maxdepth 1 -name '*.nix' -type f | sort)
  if [ "$FAILED" -ne 0 ]; then
    printf '\nNix test suite FAILED.\n' >&2
    exit 1
  fi
  echo "All Nix tests passed."
else
  echo "Skipping Nix test suite (path-scoped mode)."
fi

# ---------------------------------------------------------------------------
# 2. Dead Nix code detection
# ---------------------------------------------------------------------------
printf '\n=== [2/6] Dead Nix code ===\n'
if ! $HAS_ARGS; then
  deadnix --fail src/
  echo "No dead Nix code found."
else
  echo "Skipping deadnix (path-scoped mode)."
fi

# ---------------------------------------------------------------------------
# 3. Shell script linting (shellcheck)
# ---------------------------------------------------------------------------
printf '\n=== [3/6] Shell script linting ===\n'
if [ "${#SH_FILES[@]}" -gt 0 ]; then
  bash scripts/check-sh.sh "${SH_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-sh.sh
else
  echo "Skipping (no shell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 4. PowerShell syntax validation
# ---------------------------------------------------------------------------
printf '\n=== [4/6] PowerShell syntax validation ===\n'
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 "${PS1_FILES[@]}"
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1
else
  echo "Skipping (no PowerShell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 5. Packer template validation
# ---------------------------------------------------------------------------
printf '\n=== [5/6] Packer template validation ===\n'
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh
else
  echo "Skipping (no Packer templates to check)."
fi

# ---------------------------------------------------------------------------
# 6. Shell script validation tests
# ---------------------------------------------------------------------------
printf '\n=== [6/6] Shell script validation tests ===\n'
if ! $HAS_ARGS; then
  bash tests/scripts/script-validation-tests.sh
else
  echo "Skipping validation tests (path-scoped mode)."
fi

printf '\nAll checks passed.\n'
