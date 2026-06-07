#!/usr/bin/env bash
# test.sh — Repository test suite runner.
#
# Runs Nix test suite: auto-discovers tests/src/*.nix and evaluates each
# with nix-instantiate --eval. Future test steps (e.g., Pester) go here.
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

# ---------------------------------------------------------------------------
# 1. Nix test suite — auto-discover and run all *.nix test files
# ---------------------------------------------------------------------------
printf '\n=== [1/1] Nix test suite ===\n'
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

printf '\nAll tests passed.\n'
