# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "online-determinism" "Online determinism checks (--online)" run_online_determinism

run_online_determinism() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1

  if [ "${ctx[ONLINE]}" = "true" ]; then
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
