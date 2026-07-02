#!/usr/bin/env bash
# Runs Nix test suite, ShellCheck, and PSScriptAnalyzer.
set -euo pipefail

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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

REPO_ROOT=$(derive_repo_root)
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

# 1. Nix test suite — auto-discover and run all *.nix test files
printf '\n=== [%s] Nix test suite ===\n' "$((_step += 1))"
tmp_failed=$(mktemp) || { echo "failed to create temp file" >&2; exit 1; }
# shellcheck disable=SC2016
find tests/src -maxdepth 1 -name '*.nix' -type f | sort \
  | xargs -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" -I{} sh -c 'f="$1"; echo "Testing: $f" >&2; if ! nix-instantiate --eval "$f"; then echo "FAIL: $f" >&2; echo "$f" >> "$2"; else echo "PASS: $f" >&2; fi' _ {} "$tmp_failed"
if [ -s "$tmp_failed" ]; then
  echo "FAILED Nix tests:" >&2
  cat "$tmp_failed" >&2
  rm -f "$tmp_failed"
  exit 1
fi
rm -f "$tmp_failed"
echo "All Nix tests passed."

# 2. Shell script linting (ShellCheck)
printf '\n=== [%s] Shell script linting ===\n' "$((_step += 1))"
bash scripts/check-sh.sh

# 3. PowerShell lint (PSScriptAnalyzer)
printf '\n=== [%s] PowerShell lint ===\n' "$((_step += 1))"
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/check-pwsh.ps1

# 4. Nucleus apps smoke tests (build + --help / dry-run)
printf '\n=== [%s] Nucleus apps smoke tests ===\n' "$((_step += 1))"
bash tests/scripts/nucleus-apps-smoke-tests.sh

printf '\nAll tests passed.\n'
