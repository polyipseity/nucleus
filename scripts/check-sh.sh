#!/usr/bin/env bash
# Checks all tracked *.sh files with ShellCheck. With arguments, only provided paths.
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
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

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
      error "unsupported argument '$1'"
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
  printf '%s\0' "$@" | xargs -0 -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" shellcheck --source-path=SCRIPTDIR -x
  count="$#"
else
  if ! files="$(git ls-files '*.sh')" || [ -z "$files" ]; then
    say 'no shell scripts to check.'
    exit 0
  fi
  git ls-files -z '*.sh' | xargs -0 -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" shellcheck --source-path=SCRIPTDIR -x
  count=$(printf '%s\n' "$files" | awk 'NF { c += 1 } END { print c + 0 }')
fi

say "shell script check passed for $count files."
