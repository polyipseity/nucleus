# shellcheck shell=sh
# Validate build-time token substitution and set $_repo_root.
# Prepended at build time by Nix packaging.
# Usage: require_repo_root <label>
#   <label> — prefix for error messages (e.g. "gc", "cloud-drives").
# On failure: prints error to stderr and exits 1.
# On success: $_repo_root is set to the resolved repository root.

require_repo_root() {
  _repo_root="__REPO_ROOT__"
  if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
    printf '%s\n' "${1:-repo-root}: __REPO_ROOT__ is empty or not a directory — set NUCLEUS_REPO_ROOT at build time" >&2
    exit 1
  fi
}
