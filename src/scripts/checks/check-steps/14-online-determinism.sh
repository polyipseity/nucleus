# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "online-determinism" 14 "Online determinism checks (--online)" run_14_online_determinism

run_14_online_determinism() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  if $ONLINE; then
    if bash "$_repo_root/scripts/bump-lockfile.sh" --verify; then
      say "online determinism checks passed."
      return 0
    else
      return 1
    fi
  else
    say "skipping (use --online to run online determinism checks)."
    return 2
  fi
}
