# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

# The canonical nucleus-* command set (alphabetical) — the coverage contract
# shared with src/scripts/completions/gen-completions.sh and tests/scripts/gen-completions-tests.sh.
_NUCLEUS_COMMANDS=(ai apply bootstrap check cloud config gc utils svc test update vm)

# pascal_case <cmd> — the $nucleus<Cmd>Flags spelling gen-completions.ps1 emits
# for a command (each dash-separated segment capitalised).
pascal_case() {
  printf '%s' "$1" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }'
}

# Map a command to its .sh help source (for the --list-* introspection check).
# check-pwsh has no .sh twin (PowerShell-only) — nothing to introspect.
sh_for_command() {
  case "$1" in
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

  # 2. Coverage: every command needs a zsh completion file, a pwsh completer
  #    entry, and a defined flag inventory, so a new nucleus-* command can never
  #    silently lack autocompletions.
  local _cmd _pascal _profile="$_repo_root/src/scripts/shell/profile.ps1"
  for _cmd in "${_NUCLEUS_COMMANDS[@]}"; do
    if [ ! -f "$_repo_root/src/modules/completions/zsh/_nucleus-$_cmd" ]; then
      error "missing zsh completion file src/modules/completions/zsh/_nucleus-$_cmd"
      return 1
    fi
    # Anchored at the line start: the command name alone also matches a comment
    # or a longer command (nucleus-svc inside nucleus-service-watchdog).
    if ! grep -qE "^Register-ArgumentCompleter -CommandName nucleus-$_cmd([[:space:]]|$)" "$_profile"; then
      error "missing pwsh completer entry for nucleus-$_cmd in src/scripts/shell/profile.ps1"
      return 1
    fi
    # WHY: require the DEFINITION (line start, then optional spaces and '='). The
    # completer body names the same variable, so a match anywhere in the file
    # stayed green while nothing defined $nucleusUtilsFlags and completion
    # returned nothing.
    _pascal="$(pascal_case "$_cmd")"
    if ! grep -qE "^[$]nucleus${_pascal}Flags[[:space:]]*=" "$_profile"; then
      error "missing pwsh flag inventory \$nucleus${_pascal}Flags for nucleus-$_cmd in src/scripts/shell/profile.ps1"
      return 1
    fi
  done

  # 2b. Every flag inventory the profile REFERENCES must be DEFINED in it: the
  #     generated region is the only definition site, so a completer naming a
  #     variable gen-completions.ps1 no longer emits completes nothing.
  local _ref _refs _undefined=()
  _refs="$(grep -oE '[$]nucleus[A-Za-z0-9]*Flags' "$_profile" | LC_ALL=C sort -u)"
  while IFS= read -r _ref; do
    [ -n "$_ref" ] || continue
    if ! grep -qE "^[$]${_ref#\$}[[:space:]]*=" "$_profile"; then
      _undefined+=("$_ref")
    fi
  done <<<"$_refs"
  if [ "${#_undefined[@]}" -gt 0 ]; then
    error "profile.ps1 references flag inventories nothing defines: ${_undefined[*]}"
    return 1
  fi

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
