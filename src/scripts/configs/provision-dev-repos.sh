#!/usr/bin/env bash
# Dev repos provisioning activation, called by the home-manager entry of the same name.
#
# WHY: data-driven. The whole config.nucleus.devRepos structure is serialized as JSON and
# iterated with jq at activation time, instead of concatMapStringsSep emitting per-repo shell
# lines at eval time. That keeps the Nix side pure data and the iteration in one script.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"
. "$SCRIPT_DIR/../lib/dev-repos-provision.sh"

export HOME="$1"
export PATH="$PATH:$2"
export GIT_SSH_COMMAND="$3"

_jqBin="$4"
devReposJson="$5"

devDir="$HOME/dev"
mkdir -p "$devDir" || die -l provision-dev-repos "failed to create $devDir"

# Step 1: provision configured repositories.
# WHY: a temp file avoids subshell isolation, since while-read in a pipeline runs in a
# subshell under POSIX sh and would lose devReposErrors increments.
_repoListTmp=$(mktemp)
printf '%s\n' "$devReposJson" | "$_jqBin" -r '.repositories[] | @base64' >"$_repoListTmp"
while IFS= read -r _item; do
  _jq() { printf '%s\n' "$_item" | base64 -d | "$_jqBin" -r "$1"; }

  _name=$(_jq '.name')
  _target=$(_jq '.target')
  _symlink=$(_jq '.symlink // ""')
  _symlinkFromRepoRoot=$(_jq '.symlinkFromRepoRoot // false')
  _url=$(_jq '.url // ""')

  _resolvedTarget="$(resolve_repo_path "$_target")"

  if [ "$_symlinkFromRepoRoot" = "true" ]; then
    if _repoSymlinkTarget="$(resolve_repo_root_target)"; then
      ensure_symlink "$_repoSymlinkTarget" "$_resolvedTarget" "$_name"
    else
      report_error "repo-root symlink target unavailable for $_name"
    fi
  elif [ -n "$_symlink" ]; then
    ensure_symlink "$(resolve_repo_path "$_symlink")" "$_resolvedTarget" "$_name"
  elif [ -n "$_url" ]; then
    ensure_repo "$_url" "$_resolvedTarget" "$_name"
  else
    report_error "repository '$_name' has neither symlink nor url configured"
  fi
done <"$_repoListTmp"
rm -f "$_repoListTmp"
unset _repoListTmp _jq

# Step 2: clone submodules from the configured directories, sequentially.
_submoduleListTmp=$(mktemp)
printf '%s\n' "$devReposJson" | "$_jqBin" -r '.submoduleDirectories[] | @base64' >"$_submoduleListTmp"
while IFS= read -r _item; do
  _jq() { printf '%s\n' "$_item" | base64 -d | "$_jqBin" -r "$1"; }

  _path=$(_jq '.path')
  _recursive=$(_jq '.recursive // false | if . then "1" else "0" end')

  _resolvedPath="$(resolve_repo_path "$_path")"

  case "$_resolvedPath" in
  *\* | *\? | *\[*)
    _baseDir=$(dirname "$_resolvedPath")
    _pattern=$(basename "$_resolvedPath")
    if [ -d "$_baseDir" ]; then
      _expandedPaths=$(expand_glob_paths "$_baseDir" "$_pattern")
      if [ -z "$_expandedPaths" ]; then
        :
      else
        while IFS= read -r _matchedPath; do
          clone_directory_submodules "$_matchedPath" "$_recursive" "${_matchedPath#"$HOME"/}"
        done <<<"$_expandedPaths"
      fi
    else
      report_error "base directory $_baseDir does not exist for glob pattern '$_path'"
    fi
    ;;
  *)
    if [ -d "$_resolvedPath" ]; then
      clone_directory_submodules "$_resolvedPath" "$_recursive" "$_path"
    else
      report_error "directory '$_path' does not exist"
    fi
    ;;
  esac
done <"$_submoduleListTmp"
rm -f "$_submoduleListTmp"
unset _submoduleListTmp _jq

say -l provision-dev-repos "completed provisioning dev repositories and submodules"
if [ "$devReposErrors" -gt 0 ]; then
  warn -l provision-dev-repos "completed with $devReposErrors non-fatal error(s); see messages above."
fi
