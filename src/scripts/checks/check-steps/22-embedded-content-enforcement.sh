# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "embedded-content-enforcement" 22 "Embedded content enforcement" run_22_embedded_content_enforcement

run_22_embedded_content_enforcement() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s22_errors=0
  # Exclude this check's own file: its source contains the literal heredoc-detection patterns.
  # ref: allow-and-deny-lists.instructions.md#C5 — reason: self-refs are dynamic
  local _s22_self_sh
  _s22_self_sh="$(basename "${BASH_SOURCE[0]}")"

  # Embedded-content policy scope for POSIX: src/scripts/** (see .agents/instructions/embedded-content.instructions.md).
  local _sh_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
        src/scripts/*.sh) [ "$(basename "$_f")" = "$_s22_self_sh" ] || _sh_files+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _sh_files+=("$_f")
    done < <(find src/scripts -type f -name '*.sh' -not -name "$_s22_self_sh" -print0)
    mapfile -t _sh_files < <(printf '%s\n' "${_sh_files[@]}" | filter_gitignored)
  fi

  if [ "${#_sh_files[@]}" -gt 0 ]; then
    # Heredoc detector lives in a sibling .awk file (shellcheck policy: extract awk programs >10 lines).
    local _s22_awk_path
    _s22_awk_path="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/22-embedded-content-enforcement.awk"

    local _s22_violation
    while IFS= read -r _s22_violation; do
      _s22_errors=$((_s22_errors + 1))
      error "$_s22_violation"
    done < <(awk -f "$_s22_awk_path" "${_sh_files[@]}")
  fi

  if [ "$_s22_errors" -gt 0 ]; then
    say "  Extract heredocs above 30 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    return 1
  fi

  say "no embedded-content heredoc violations found."
  return 0
}
