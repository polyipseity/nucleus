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

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$(git ls-files '*.sh')"
fi

if [ -z "$files" ]; then
  printf '%s\n' 'No shell scripts to check.'
  exit 0
fi

# Run ShellCheck once across the selected file set for consistent output ordering.
# Use -0 with xargs to safely handle filenames with spaces or special characters.
git ls-files -z '*.sh' | xargs -0 shellcheck

count=$(git ls-files '*.sh' | awk 'NF { c += 1 } END { print c + 0 }')
printf 'Shell script check passed for %s files.\n' "$count"
