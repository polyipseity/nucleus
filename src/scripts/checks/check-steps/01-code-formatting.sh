# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "code-formatting" "Code formatting and linting" run_code_formatting

run_code_formatting() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _exit=0

  if $_has_args; then
    treefmt "${_files[@]}" || _exit=$?
  else
    treefmt || _exit=$?
  fi

  if [ $_exit -ne 0 ]; then
    error "treefmt failed with exit code $_exit"
    return $_exit
  fi
  say "treefmt OK."

  if [ "$(uname)" = "Darwin" ]; then
    local _workflow_files=()
    if $_has_args; then
      local _f
      for _f in "${_files[@]}"; do
        case "$_f" in
        .github/workflows/* | */.github/workflows/*) _workflow_files+=("$_f") ;;
        esac
      done
      if [ "${#_workflow_files[@]}" -eq 0 ]; then
        say "skipping actionlint/zizmor (no workflow files in scope)."
      else
        actionlint "${_workflow_files[@]}" || _exit=$?
        if [ $_exit -eq 0 ]; then
          say "actionlint OK."
        else
          error "actionlint failed with exit code $_exit"
        fi
        zizmor "${_workflow_files[@]}" || _exit=$?
        if [ $_exit -eq 0 ]; then
          say "zizmor OK."
        else
          error "zizmor failed with exit code $_exit"
        fi
      fi
    else
      if [ -d .github/workflows ]; then
        while IFS= read -r -d '' _f; do
          _workflow_files+=("$_f")
        done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
      fi
      if [ "${#_workflow_files[@]}" -eq 0 ]; then
        say "skipping actionlint/zizmor (no workflow files)."
      else
        actionlint "${_workflow_files[@]}" || _exit=$?
        if [ $_exit -eq 0 ]; then
          say "actionlint OK."
        else
          error "actionlint failed with exit code $_exit"
        fi
        zizmor "${_workflow_files[@]}" || _exit=$?
        if [ $_exit -eq 0 ]; then
          say "zizmor OK."
        else
          error "zizmor failed with exit code $_exit"
        fi
      fi
    fi
  fi

  if [ $_exit -ne 0 ]; then
    return $_exit
  fi

  local _pkr_exit=0
  if [ "${#PKR_FILES[@]}" -gt 0 ]; then
    bash scripts/check-packer.sh --validate-only "${PKR_FILES[@]}" || _pkr_exit=$?
  elif ! $_has_args; then
    bash scripts/check-packer.sh --validate-only || _pkr_exit=$?
  else
    say "skipping check-packer (no Packer templates to check)."
  fi

  if [ $_pkr_exit -eq 0 ]; then
    say "Packer template validation passed."
  fi

  return $_pkr_exit
}
