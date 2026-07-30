# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "activation-token-placeholder" 20 "Activation script token placeholder in comment check" run_20_activation_token_placeholder

run_20_activation_token_placeholder() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _act_temp
  _act_temp="$(mktemp)" || { error "failed to create temp file"; return 1; }

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in *.sh|*.zsh) printf '%s\0' "$_f" ;; esac
    done | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true
  else
    find src/scripts -type f \( -name '*.sh' -o -name '*.zsh' \) -print0 \
      | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true
  fi

  if [ -s "$_act_temp" ]; then
    error "token placeholder strings found in script comments:"
    sort -u "$_act_temp" | while IFS= read -r _line; do
      error "  $_line"
    done
    rm -f "$_act_temp"
    return 1
  else
    say "no token placeholder strings in script comments."
  fi

  rm -f "$_act_temp"
  return 0
}
