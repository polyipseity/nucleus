# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 18 "Online determinism checks (--verify)" run_18_online_determinism

run_18_online_determinism() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1

  if $VERIFY; then
    if bash "$_repo_root/scripts/bump-lockfile.sh" --verify; then
      say "online determinism checks passed."
      return 0
    else
      return 1
    fi
  else
    say "skipping (use --verify to run online determinism checks)."
    return 0
  fi
}
