#!/usr/bin/env bash
# test.sh — Repository test suite runner.
#
# Runs Nix test suite, ShellCheck, and PSScriptAnalyzer.
# Heavy lint moved here from check.sh so pre-commit stays fast.
#
# No file arguments accepted — always runs the full test suite.
#
# Exit conditions:
#   0 on success; non-zero on any test failure.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT=$(resolve_nucleus_root)
cd "$REPO_ROOT"

usage() {
  usage_std "test.sh" "" "Run the repository test suite."
}

# No positional arguments accepted.
if [ "$#" -gt 0 ]; then
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
      printf '%s\n' "error: unexpected argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

_step=0

# ---------------------------------------------------------------------------
# 1. Nix test suite — auto-discover and run all *.nix test files
# ---------------------------------------------------------------------------
printf '\n=== [%s] Nix test suite ===\n' "$((_step += 1))"
echo "Running Nix unit tests..."
FAILED=0
while IFS= read -r test; do
  echo "Running: $test"
  nix-instantiate --eval "$test" || FAILED=1
done < <(find tests/src -maxdepth 1 -name '*.nix' -type f | sort)
if [ "$FAILED" -ne 0 ]; then
  printf '\nNix test suite FAILED.\n' >&2
  exit 1
fi
echo "All Nix tests passed."

# ---------------------------------------------------------------------------
# 2. Shell script linting (ShellCheck)
# ---------------------------------------------------------------------------
printf '\n=== [%s] Shell script linting ===\n' "$((_step += 1))"
bash scripts/check-sh.sh

# ---------------------------------------------------------------------------
# 3. PowerShell lint (PSScriptAnalyzer)
# ---------------------------------------------------------------------------
printf '\n=== [%s] PowerShell lint ===\n' "$((_step += 1))"
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1

printf '\nAll tests passed.\n'
