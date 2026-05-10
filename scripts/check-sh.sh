#!/usr/bin/env sh
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
set -eu

# --source-path=SCRIPTDIR lets shellcheck resolve `# shellcheck source=` directives
# relative to each script's own directory (e.g. bootstrap-versions.env alongside bootstrap.sh).
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
