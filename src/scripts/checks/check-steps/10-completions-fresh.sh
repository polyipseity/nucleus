# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

# The canonical nucleus-* command set (alphabetical) — the coverage contract
# shared with src/scripts/completions/gen-completions.sh and tests/scripts/gen-completions-tests.sh.
_NUCLEUS_COMMANDS=(ai apply bootstrap check cloud config gc gs-pdf-opt service-watchdog svc test update vm)

# Map a command to its .sh help source (for the --list-* introspection check).
# check-pwsh has no .sh twin (PowerShell-only) — nothing to introspect.
sh_for_command() {
  case "$1" in
  service-watchdog) printf '%s\n' "src/scripts/services/service-watchdog.sh" ;;
  *) printf '%s\n' "scripts/$1.sh" ;;
  esac
}

register_step "completions-fresh" "Completions freshness (generated files match)" run_completions_fresh

run_completions_fresh() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1

  # 1. Generated files must match the generator output (drift = hard failure).
  if ! bash "$_repo_root/src/scripts/completions/gen-completions.sh" --check; then
    error "generated completions are stale — run src/scripts/completions/gen-completions.sh to regenerate"
    return 1
  fi

  # 2. Coverage: every command needs a zsh completion file and a pwsh
  #    completer entry, so a new nucleus-* command can never silently lack
  #    autocompletions.
  local _cmd
  for _cmd in "${_NUCLEUS_COMMANDS[@]}"; do
    if [ ! -f "$_repo_root/src/modules/completions/zsh/_nucleus-$_cmd" ]; then
      error "missing zsh completion file src/modules/completions/zsh/_nucleus-$_cmd"
      return 1
    fi
    if ! grep -q "nucleus-$_cmd" "$_repo_root/src/scripts/shell/profile.ps1"; then
      error "missing pwsh completer entry for nucleus-$_cmd in src/scripts/shell/profile.ps1"
      return 1
    fi
  done

  # 3. Introspection contract: a --list-* flag wired via _call_program must
  #    exist in the command's --help output (completion values come from the
  #    live CLI, so the flag must be real).
  local _sh_rel="" _zsh_file="" _help_tmp="" _list_flags="" _flag=""
  for _cmd in "${_NUCLEUS_COMMANDS[@]}"; do
    _zsh_file="$_repo_root/src/modules/completions/zsh/_nucleus-$_cmd"
    if ! grep -q '_call_program' "$_zsh_file"; then
      continue
    fi
    _sh_rel="$(sh_for_command "$_cmd")"
    if [ -z "$_sh_rel" ]; then
      continue
    fi
    _help_tmp="$(mktemp)"
    # check-suppress:suppression_doc: help output is stdout-only per the output-format contract; stderr is suppressed and --help failures are caught below.
    if ! bash "$_repo_root/$_sh_rel" --help >"$_help_tmp" 2>/dev/null; then
      error "nucleus-$_cmd: --help failed during introspection"
      rm -f "$_help_tmp"
      return 1
    fi
    _list_flags="$(grep -oE -- '--list-[a-z0-9-]+' "$_zsh_file" | LC_ALL=C sort -u)"
    if [ -n "$_list_flags" ]; then
      while IFS= read -r _flag; do
        if ! grep -q -- "$_flag" "$_help_tmp"; then
          error "nucleus-$_cmd: completion wires $_flag but --help output lacks it"
          rm -f "$_help_tmp"
          return 1
        fi
      done <<<"$_list_flags"
    fi
    rm -f "$_help_tmp"
  done

  say "completions freshness passed."
  return 0
}
