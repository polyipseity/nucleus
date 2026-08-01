# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "config-method-compliance" 19 "Config method compliance" run_19_config_method_compliance

run_19_config_method_compliance() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _cfg_errors=0
  local _cfg_dir="src/modules/configs"
  local _cfg_par_tmpdir
  _cfg_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _cfg_errors=$((_cfg_errors + 1)); }

  # Single-pass: collect all config file basenames, run one grep across src/
  local _cfg_patterns
  _cfg_patterns=$(mktemp) || { error "failed to create temp file"; _cfg_errors=$((_cfg_errors + 1)); }
  find "$_cfg_dir" -type f -exec basename {} \; | sort -u > "$_cfg_patterns"
  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns
  find src/ \( -name '*.nix' -o -name '*.ps1' -o -name '*.sh' \) -not -path '*/vendor/*' -not -path '*/configs/*' -print \
    | filter_gitignored \
    | xargs grep -n -F -f "$_cfg_patterns" 2>/dev/null \
    || true  # check-suppress:suppression_doc: xargs grep exits 1 when no config basename collisions are found; no match is the expected state
  rm -f "$_cfg_patterns"

  # Check for configs. method usage
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  find "$_cfg_dir" -type f -print0 \
    | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _basename=$(basename "$_f")
      # Skip infrastructure files and Nix modules inside configs/  # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
      case "$_basename" in
        .gitkeep|.gitignore|*.schema.json) exit 0 ;;
      esac
      # Skip agent customization files (consumed as a directory via Method 4)  # ref: allow-and-deny-lists.instructions.md#A2 -- agents/* consumed as directory
      case "$_f" in
        */configs/agents/*) exit 0 ;;
      esac
      _result_file="$_tmpdir/${_basename}.result"
      _relpath="${_f#*configs/}"
      # Check for disallowed config methods
      if grep -q "^[^#]*configs\." "$_f" 2>/dev/null; then
        echo "ERROR:$_relpath uses configs. method" >> "$_result_file"
      fi
    ' _ "$_cfg_par_tmpdir"

  # Aggregate results
  local _result_file _eline
  for _result_file in "$_cfg_par_tmpdir"/*.result; do
    [ -f "$_result_file" ] || continue
    while IFS= read -r _eline; do
      case "$_eline" in
        ERROR:*)
          _cfg_errors=$((_cfg_errors + 1))
          error "${_eline#ERROR:}"
          ;;
      esac
    done < "$_result_file"
  done
  rm -rf -- "$_cfg_par_tmpdir"

  if [ "$_cfg_errors" -gt 0 ]; then
    error "config method compliance check failed with $_cfg_errors error(s)"
    return 1
  fi
  say "config method compliance passed."
  return 0
}
