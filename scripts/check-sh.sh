#!/usr/bin/env bash
# scripts/check-sh.sh — Validate shell script syntax and lint quality with ShellCheck.
#
# Usage:
#   check-sh.sh [path ...]
#
# Behavior:
#   - With no arguments, checks all tracked `*.sh` files from Git.
#   - With arguments, checks only the provided paths.
#
# Environment:
#   - Requires `git` and `shellcheck` in PATH (provided by flake app wrapper).
#
# Exit conditions:
#   - Exits non-zero on any ShellCheck finding at error/warning level.
set -euo pipefail

# Source shared library when available; fall back to inline helpers for
# standalone execution (e.g. Nix pre-commit hooks where the script is
# copied to a flat store path).
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../src/scripts/lib.sh" ]; then
  . "$SCRIPT_DIR/../src/scripts/lib.sh"
else
  # inline usage_std — emit standardized usage text
  usage_std() {
    printf 'usage: %s %s\n' "$1" "${2:-}"
    [ "$#" -gt 2 ] && printf '  %s\n' "$3"
  }
  # inline resolve_nucleus_root
  resolve_nucleus_root() {
    [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ] && { printf '%s\n' "$NUCLEUS_REPO_ROOT"; return 0; }
    printf '%s\n' "${HOME}/dev/nucleus"
  }
fi

usage() {
  usage_std "check-sh.sh" "[path ...]" "Validate shell script syntax and lint quality with ShellCheck. With no arguments, checks all tracked *.sh files from Git. With arguments, checks only the provided paths."
}

# --source-path=SCRIPTDIR lets shellcheck resolve `# shellcheck source=` directives
# relative to each script's own directory (e.g. bootstrap-versions.env alongside bootstrap.sh).
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

if [ "$#" -gt 0 ]; then
  printf '%s\0' "$@" | xargs -0 shellcheck --source-path=SCRIPTDIR -x
  count="$#"
else
  if ! files="$(git ls-files '*.sh')" || [ -z "$files" ]; then
    printf '%s\n' 'No shell scripts to check.'
    exit 0
  fi
  git ls-files -z '*.sh' | xargs -0 shellcheck --source-path=SCRIPTDIR -x
  count=$(printf '%s\n' "$files" | awk 'NF { c += 1 } END { print c + 0 }')
fi

printf 'Shell script check passed for %s files.\n' "$count"
