# shellcheck shell=sh
# Dev repos provisioning activation.
# Called by home-manager activation devReposProvision.
#
# This is a data-driven replacement for the previous Nix-generated inline
# shell code. Instead of concatMapStringsSep producing per-repo shell lines
# at eval time, the entire config.nucleus.devRepos structure is serialized
# as JSON and consumed at activation time via jq
# iteration. This keeps the Nix side pure data and moves all iteration
# logic into a single maintainable shell script.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"
. "$SCRIPT_DIR/../lib/dev-repos-provision-lib.sh"

export HOME="$1"
export PATH="$PATH:$2"
export GIT_SSH_COMMAND="$3"

repoRoot="$4"
_jqBin="$5"
devReposJson="$6"

if [ -z "$repoRoot" ] || [ ! -d "$repoRoot" ]; then
  echo "devReposProvision: repo root is empty or invalid — check NUCLEUS_REPO_ROOT at build time" >&2
  exit 1
fi

devDir="$HOME/dev"
mkdir -p "$devDir" || { echo "devReposProvision: failed to create $devDir" >&2; exit 1; }

# Step 1: Provision configured repositories
# Use temp file to avoid subshell isolation (while-read in pipelines
# creates a subshell in POSIX sh, losing devReposErrors increments).
_repoListTmp=$(mktemp)
printf '%s\n' "$devReposJson" | "$_jqBin" -r '.repositories[] | @base64' > "$_repoListTmp"
while IFS= read -r _item; do
  _jq() { printf '%s\n' "$_item" | base64 -d | "$_jqBin" -r "$1"; }

  _name=$(_jq '.name')
  _target=$(_jq '.target')
  _symlink=$(_jq '.symlink // ""')
  _symlinkFromRepoRoot=$(_jq '.symlinkFromRepoRoot // false')
  _url=$(_jq '.url // ""')

  _resolvedTarget="$(resolve_repo_path "$_target")"

  if [ "$_symlinkFromRepoRoot" = "true" ]; then
    if _repoSymlinkTarget="$(resolve_repo_root_target "$repoRoot")"; then
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
done < "$_repoListTmp"
rm -f "$_repoListTmp"
unset _repoListTmp _jq

# Step 2: Clone submodules from specified directories (sequential processing)
_submoduleListTmp=$(mktemp)
printf '%s\n' "$devReposJson" | "$_jqBin" -r '.submoduleDirectories[] | @base64' > "$_submoduleListTmp"
while IFS= read -r _item; do
  _jq() { printf '%s\n' "$_item" | base64 -d | "$_jqBin" -r "$1"; }

  _path=$(_jq '.path')
  _recursive=$(_jq '.recursive // false | if . then "1" else "0" end')

  _resolvedPath="$(resolve_repo_path "$_path")"

  # Check if path contains glob characters
  case "$_resolvedPath" in
    *\*|*\?|*\[*)
      # Glob pattern detected; expand it
      _baseDir=$(dirname "$_resolvedPath")
      _pattern=$(basename "$_resolvedPath")
      if [ -d "$_baseDir" ]; then
        _expandedPaths=$(expand_glob_paths "$_baseDir" "$_pattern")
        if [ -z "$_expandedPaths" ]; then
          # No matches for configured glob; benign no-op.
          :
        else
          while IFS= read -r _matchedPath; do
            clone_directory_submodules "$_matchedPath" "$_recursive" "${_matchedPath#$HOME/}"
          done <<< "$_expandedPaths"
        fi
      else
        report_error "base directory $_baseDir does not exist for glob pattern '$_path'"
      fi
      ;;
    *)
      # No glob; process literal path
      if [ -d "$_resolvedPath" ]; then
        clone_directory_submodules "$_resolvedPath" "$_recursive" "$_path"
      else
        report_error "directory '$_path' does not exist"
      fi
      ;;
  esac
done < "$_submoduleListTmp"
rm -f "$_submoduleListTmp"
unset _submoduleListTmp _jq

echo "devReposProvision: completed provisioning dev repositories and submodules"
if [ "$devReposErrors" -gt 0 ]; then
  echo "devReposProvision: completed with $devReposErrors non-fatal error(s); see messages above." >&2
fi
