#!/usr/bin/env bash
# Checks all tracked *.sh files with treefmt (ShellCheck via treefmt-nix). With arguments, only provided paths.
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
  usage_std "check-sh.sh" "[--scoped] [path ...]" "Validate shell script syntax and lint quality with treefmt (ShellCheck). With no arguments, checks all tracked *.sh files from Git. With arguments, checks only the provided paths. Use --scoped to skip whole-repo discovery when no paths are given."
}

# --source-path=SCRIPTDIR lets shellcheck resolve `# shellcheck source=` directives
# relative to each script's own directory (e.g. bootstrap-versions.env alongside bootstrap.sh).
# -x enables following external sources.
# Flag order: long options first, -x second. Flags live in src/treefmt.nix (source-path = "SCRIPTDIR"); Windows twin scripts/check-sh.ps1 passes --source-path per file.
_SCOPED=false
while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --scoped)
    _SCOPED=true
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
  # Paths given: always run treefmt on them, regardless of --scoped.
  treefmt --fail-on-change "$@"
  count="$#"
elif $_SCOPED; then
  # --scoped with no paths: nothing to check.
  say 'no shell scripts to check (scoped mode).'
  exit 0
else
  files="$(git ls-files '*.sh' ':(exclude)vendor/')" || true # check-suppress:suppression_doc: git ls-files returns 1 when no matches found
  if [ -z "$files" ]; then
    say 'no shell scripts to check.'
    exit 0
  fi
  # shellcheck disable=SC2086 # reason: word splitting intentional for treefmt file args
  treefmt --fail-on-change $files
  count=$(printf '%s\n' "$files" | awk 'NF { c += 1 } END { print c + 0 }')
fi

say "shell script check passed for $count files."
