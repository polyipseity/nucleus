#!/usr/bin/env bash
# check.sh — Consolidated repository validation script.
#
# Runs all repository checks in sequence:
#   1. Dead Nix code detection (deadnix)
#   2. Shell script linting (shellcheck)
#   3. PowerShell syntax validation
#   4. Packer template validation
#   5. Shell script validation tests
#
# With arguments, passes them through to individual checkers that support
# path filtering (check-sh.sh, check-pwsh.ps1, check-packer.sh) and skips
# whole-repo checks (deadnix, script validation).
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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT=$(resolve_nucleus_root)
cd "$REPO_ROOT"

usage() {
  usage_std "check.sh" "[path ...]" "Run all repository validation checks in sequence. With arguments, passes paths through to supporting checkers and skips whole-repo checks (deadnix, script validation)."
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
# 1. Dead Nix code detection
# ---------------------------------------------------------------------------
printf '\n=== [1/5] Dead Nix code ===\n'
if ! $HAS_ARGS; then
  deadnix --fail src/
  echo "No dead Nix code found."
else
  echo "Skipping deadnix (path-scoped mode)."
fi

# ---------------------------------------------------------------------------
# 2. Shell script linting (shellcheck)
# ---------------------------------------------------------------------------
printf '\n=== [2/5] Shell script linting ===\n'
if [ "${#SH_FILES[@]}" -gt 0 ]; then
  bash scripts/check-sh.sh "${SH_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-sh.sh
else
  echo "Skipping (no shell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 3. PowerShell syntax validation
# ---------------------------------------------------------------------------
printf '\n=== [3/5] PowerShell syntax validation ===\n'
if [ "${#PS1_FILES[@]}" -gt 0 ]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1 "${PS1_FILES[@]}"
elif ! $HAS_ARGS; then
  pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1
else
  echo "Skipping (no PowerShell scripts to check)."
fi

# ---------------------------------------------------------------------------
# 4. Packer template validation
# ---------------------------------------------------------------------------
printf '\n=== [4/5] Packer template validation ===\n'
if [ "${#PKR_FILES[@]}" -gt 0 ]; then
  bash scripts/check-packer.sh "${PKR_FILES[@]}"
elif ! $HAS_ARGS; then
  bash scripts/check-packer.sh
else
  echo "Skipping (no Packer templates to check)."
fi

# ---------------------------------------------------------------------------
# 5. Shell script validation tests
# ---------------------------------------------------------------------------
printf '\n=== [5/5] Shell script validation tests ===\n'
if ! $HAS_ARGS; then
  bash tests/scripts/script-validation-tests.sh
else
  echo "Skipping validation tests (path-scoped mode)."
fi

printf '\nAll checks passed.\n'
