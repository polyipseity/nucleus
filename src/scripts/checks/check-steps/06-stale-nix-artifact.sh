# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 6 "Stale Nix build artifact check" run_06_stale_nix_artifact

run_06_stale_nix_artifact() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _cnba_output
  _cnba_output="$("$_repo_root/scripts/cleanup-nix.sh" --dry-run 2>&1)" || true

  if echo "$_cnba_output" | grep -q "would remove stale Nix build symlink"; then
    error "stale Nix build artifacts found:"
    echo "$_cnba_output" | while IFS= read -r _cnba_line; do
      error "  $_cnba_line"
    done
    return 1
  else
    say "no stale Nix build artifacts found."
    return 0
  fi
}
