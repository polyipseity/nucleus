# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "nix-search-path" 9 "Nix search path tests" run_09_nix_search_path

run_09_nix_search_path() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _nspt_exit=0

  # Skip if has_args with no Nix files (scoped mode, no relevant files)
  if $_has_args && [ "${#NIX_FILES[@]}" -eq 0 ] && [ "${#_files[@]}" -eq 0 ]; then
    say "==== 9: Nix search path tests ==== SKIPPED (no Nix files to check with args)"
    return 2
  fi

  echo "--- test output ---"
  bash tests/scripts/nix-search-path-tests.sh || _nspt_exit=$?
  echo "--- end test output ---"

  return $_nspt_exit
}
