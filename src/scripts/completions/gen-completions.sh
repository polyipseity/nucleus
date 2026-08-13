#!/usr/bin/env bash
# Generate zsh completion files for every nucleus-* command from its --help
# output (the CLI is the source of truth; the help contract is enforced by
# nucleus-output-format.instructions.md). Idempotent: generating twice yields
# byte-identical files. --check regenerates into a temp dir and fails listing
# every differing checked-in file (enforced by check step 10-completions-fresh).
# Generated files must not be edited by hand.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

REPO_ROOT="$(derive_repo_root)"
COMPLETIONS_DIR="$REPO_ROOT/src/modules/completions/zsh"

# The canonical nucleus-* command set (alphabetical) — the coverage contract
# shared with check step 10-completions-fresh and the generator tests.
COMMANDS=(ai apply audit-store bootstrap bump-lockfile check check-packer check-pwsh check-sh cleanup-nix cloud-setup config gc gs-pdf-opt health-check replica-reset replica-sync service-watchdog svc test update vm)

# Map a command to its .sh help source (the executable contract).
# check-pwsh has no .sh twin (PowerShell-only); service-watchdog lives under src/scripts.
sh_for_command() {
  case "$1" in
  service-watchdog) printf '%s\n' "src/scripts/services/service-watchdog.sh" ;;
  check-pwsh) printf '%s\n' "" ;;
  *) printf '%s\n' "scripts/$1.sh" ;;
  esac
}

# Known subcommand inventory for commands whose usage summary line does not
# enumerate subcommands cleanly (config embeds argument syntax between names).
# Subcommand descriptions are still extracted from the live --help body.
known_subcommands() {
  case "$1" in
  svc) printf '%s\n' "list|status|start|stop|restart|enable|disable|verify|endpoint|logs|log-paths|log-config" ;;
  vm) printf '%s\n' "setup|sync|build-system|list|status|start|stop|upgrade|reset|android-config|inject|gc|resize|pack|unpack" ;;
  ai) printf '%s\n' "sync|list|status|endpoint|config" ;;
  config) printf '%s\n' "get|set|list" ;;
  esac
}

usage() {
  usage_std "$(basename "$0")" "generate|--check|--help" "Generate zsh completion files for every nucleus-* command from its --help output. Default action: generate (write files in place). --check regenerates into a temp dir and fails (exit 1) listing every differing file. Files are generated — do not edit by hand."
}

# extract_flags <help-file> — flag tokens from two sources, excluding the
# always-emitted -h/--help group, deduped and sorted in the C locale for
# byte-stable output:
#   1. the usage summary line's bracketed groups ([--ai-sync|--no-ai-sync],
#      [-q|--quiet], [--dry-run], [--target-user=<name>]). Only tokens INSIDE
#      brackets are taken, so subcommand words like log-config never leak a
#      -config token; |-alternates split into separate flags; `--flag=<name>`
#      and `--flag <name>` value placeholders are stripped (the space form
#      matters because placeholders like <comma-separated> embed dashes); and
#      the bare -- end-of-options marker ([-- <apply-args>...]) never matches
#      because a flag token requires a letter after the dashes.
#   2. each help-body flag line: the leading flag cluster of the line
#      (whitespace then '-' then |-separated flags). Anchoring to the line
#      start avoids description words like "machine-readable" leaking tokens.
extract_flags() {
  {
    # Usage summary line: the bracketed groups only.
    grep -E '^usage: ' "$1" | head -n1 |
      grep -oE '\[[^]]*\]' |
      sed -E 's/^\[//; s/\]$//' |
      sed -E 's/ <[^]]*>//g; s/=<[^]]*>//g' |
      tr '|' '\n' |
      grep -oE -- '(-|--)[a-z0-9][a-z0-9-]*'
    # Help-body flag lines: the leading |-separated flag cluster of each line.
    grep -E '^[[:space:]]*-' "$1" |
      grep -oE '^[[:space:]]*(-|--)[a-z0-9][a-z0-9-]*(\|(-|--)[a-z0-9][a-z0-9-]*)*' |
      tr '|' '\n' |
      sed -E 's/^[[:space:]]*//'
  } |
    grep -vxE -- '-h|--help' |
    LC_ALL=C sort -u || true # check-suppress:suppression_doc: no flag tokens in either source is a valid result (help-only commands) — the pipeline then emits nothing.
}

# extract_subcommands <help-file> — subcommand names from the usage summary
# line: '|' -separated tokens that are bare lowercase [a-z0-9-] words.
extract_subcommands() {
  grep -E '^usage: ' "$1" | head -n1 |
    sed -E 's/^usage: [^[:space:]]+[[:space:]]*//' |
    tr '|' '\n' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    grep -E '^[a-z][a-z0-9-]*$' || true # check-suppress:suppression_doc: no subcommands in the usage line is a valid result — the pipeline then emits nothing.
}

# sub_description <help-file> <subcommand> — the first help-body line whose
# first token is the subcommand, minus leading [arg]/<arg> groups; '' when none.
sub_description() {
  local _line
  _line="$(grep -E "^[[:space:]]*${2}($|[[:space:]])" "$1" | head -n1)" || true # check-suppress:suppression_doc: no help-body line for the subcommand → empty description.
  [ -n "$_line" ] || return 0
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line#"${2}"}"
  _line="${_line#"${_line%%[![:space:]]*}"}"
  while true; do
    case "$_line" in
    '['*']'*)
      _line="${_line#*]}"
      _line="${_line#"${_line%%[![:space:]]*}"}"
      ;;
    '<'*'>'*)
      _line="${_line#*>}"
      _line="${_line#"${_line%%[![:space:]]*}"}"
      ;;
    *) break ;;
    esac
  done
  printf '%s\n' "$_line" |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/\.$//'
}

# escape_zsh_dquote <text> — escape characters that would expand inside zsh
# double quotes so extracted descriptions stay literal.
escape_zsh_dquote() {
  # shellcheck disable=SC2016 # reason: the sed program is a regex metacharacter string for the tool, not shell expansion.
  printf '%s\n' "$1" | sed -E 's/([\\"$`])/\\\1/g'
}

# flag_desc <flag> — human-readable flag description: leading dashes stripped,
# remaining dashes turned into spaces (--tool-cache-gc → "tool cache gc").
flag_desc() {
  local _f="$1"
  _f="${_f#--}"
  _f="${_f#-}"
  _f="${_f//-/' '}"
  printf '%s\n' "$_f"
}

# capture_help <command> <out-file> — run the command's .sh --help into the
# file; every .sh command supports --help, so a failure is a real bug.
capture_help() {
  local _cmd="$1" _out="$2" _sh_rel
  _sh_rel="$(sh_for_command "$_cmd")"
  : >"$_out"
  [ -n "$_sh_rel" ] || return 0 # check-pwsh: no .sh source — the fixed --help group only.
  # check-suppress:suppression_doc: help output is stdout-only per the output-format contract; stderr is suppressed.
  if ! bash "$REPO_ROOT/$_sh_rel" --help >"$_out" 2>/dev/null; then
    error "nucleus-$_cmd: --help failed (every .sh command supports --help; a failure is a real bug)"
    exit 1
  fi
}

# emit_svc_glue — the hand-written services.json runtime function, preserved
# verbatim (behavioral glue exception; only the flag/subcommand inventory is
# generated). Per-command glue template for nucleus-svc.
emit_svc_glue() {
  cat <<'ZSH_GLUE'
_nucleus_svc_services() {
  local services_json
  if [[ -n "$NUCLEUS_REPO_ROOT" ]]; then
    services_json="$NUCLEUS_REPO_ROOT/src/modules/services.json"
  else
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    services_json="$repo_root/src/modules/services.json"
  fi
  if [[ -f "$services_json" ]] && command -v jq >/dev/null 2>&1; then
    local -a svc_names
    svc_names=("${(@f)$(jq -r 'to_entries | .[] | select(.value | type == "object") | .key' "$services_json" 2>/dev/null)}")
    _describe -t services 'service' svc_names
  fi
}
ZSH_GLUE
}

# generate_command_file <command> <out-dir> — write src/modules/completions/zsh/_nucleus-<command>.
generate_command_file() {
  local _cmd="$1" _out_dir="$2"
  local _out_file="$_out_dir/_nucleus-$_cmd"
  local _tmp_file="$_out_dir/.tmp-_nucleus-$_cmd.$$"
  local _help_tmp="" _known="" _sub_line="" _flag_lines="" _dyn_state="" _s="" _desc="" _f=""
  local -a _subs=() _flags_arr=()

  _help_tmp="$(mktemp)"
  capture_help "$_cmd" "$_help_tmp"

  # Subcommand inventory: the known table when the usage line does not
  # enumerate subcommands cleanly; usage-line extraction otherwise.
  _known="$(known_subcommands "$_cmd")"
  if [ -n "$_known" ]; then
    IFS='|' read -r -a _subs <<<"$_known"
  else
    while IFS= read -r _s; do
      _subs+=("$_s")
    done < <(extract_subcommands "$_help_tmp")
  fi

  # Subcommand positional spec (index 1) with per-sub descriptions.
  if [ "${#_subs[@]}" -gt 0 ]; then
    _sub_line="1:subcommand:(("
    local _sub_first=1
    for _s in "${_subs[@]}"; do
      _desc="$(sub_description "$_help_tmp" "$_s")"
      if [ -n "$_desc" ]; then
        _desc="$(escape_zsh_dquote "$_desc")"
      else
        _desc=""
      fi
      if [ "$_sub_first" -eq 1 ]; then
        _sub_line="$_sub_line$_s \"$_desc\""
        _sub_first=0
      else
        _sub_line="$_sub_line $_s \"$_desc\""
      fi
    done
    _sub_line="$_sub_line))"
  fi

  # Flags: sorted, deduped; a --<X> flag gets dynamic value completion when the
  # command also exposes --list-<X> (values come from the live CLI at runtime).
  while IFS= read -r _f; do
    _flags_arr+=("$_f")
  done < <(extract_flags "$_help_tmp")

  local _suffix="" _spec="" _i=0 _j=0 _list_suffix=""
  local -a _list_suffixes=()
  for _j in "${!_flags_arr[@]}"; do
    case "${_flags_arr[$_j]}" in
    --list-*) _list_suffixes+=("${_flags_arr[$_j]#--list-}") ;;
    *) : ;;
    esac
  done
  for _i in "${!_flags_arr[@]}"; do
    _f="${_flags_arr[$_i]}"
    _spec="${_f}[$(flag_desc "$_f")]"
    _suffix="${_f#--}"
    if [ -n "$_suffix" ]; then
      for _list_suffix in "${_list_suffixes[@]}"; do
        if [ "$_list_suffix" = "$_suffix" ]; then
          # --<X> gets dynamic value completion when the command also exposes
          # --list-<X> (values come from the live CLI at runtime).
          _spec="${_f}:${_suffix%s} name:->$_suffix"
          _dyn_state="$_suffix"
          break
        fi
      done
    fi
    if [ -n "$_flag_lines" ]; then
      _flag_lines="$_flag_lines
$_spec"
    else
      _flag_lines="$_spec"
    fi
  done

  # Assemble the file via a temp + atomic rename so concurrent readers (e.g.
  # the smoke tests) never observe a half-written completion file.
  {
    printf '#compdef nucleus-%s\n' "$_cmd"
    printf '\n'
    printf '# GENERATED by src/scripts/completions/gen-completions.sh — do not edit.\n'
    printf '\n'
    if [ "$_cmd" = "svc" ]; then
      emit_svc_glue
      printf '\n'
    fi
    printf '_arguments \\\n'
    printf "  '(-h --help)'{--help,-h}'[Show usage]'"
    if [ -n "$_sub_line" ] || [ -n "$_flag_lines" ]; then
      printf ' \\\n'
    else
      printf '\n'
    fi
    if [ -n "$_sub_line" ]; then
      printf "  '%s'" "$_sub_line"
      if [ -n "$_flag_lines" ]; then
        printf ' \\\n'
      else
        printf '\n'
      fi
    fi
    if [ -n "$_flag_lines" ]; then
      local _n=0 _i2=0 _line
      while IFS= read -r _line; do
        _n=$((_n + 1))
      done <<<"$_flag_lines"
      while IFS= read -r _line; do
        _i2=$((_i2 + 1))
        printf "  '%s'" "$_line"
        if [ "$_i2" -lt "$_n" ]; then
          printf ' \\\n'
        else
          printf '\n'
        fi
      done <<<"$_flag_lines"
    fi
    if [ -n "$_dyn_state" ]; then
      printf "case \$state in\n"
      printf '%s)\n' "$_dyn_state"
      printf "  _call_program '%s' nucleus-%s --list-%s\n" "$_dyn_state" "$_cmd" "$_dyn_state"
      printf '  ;;\n'
      printf 'esac\n'
    fi
  } >"$_tmp_file"
  mv -f "$_tmp_file" "$_out_file"
  rm -f "$_help_tmp"
}

# generate_dispatcher <out-dir> — regenerate the _nucleus dispatcher that
# completes `nucleus-<TAB>` with every command name.
generate_dispatcher() {
  local _out_dir="$1"
  local _out_file="$_out_dir/_nucleus"
  local _tmp_file="$_out_dir/.tmp-_nucleus.$$"
  local _joined="" _c
  for _c in "${COMMANDS[@]}"; do
    if [ -n "$_joined" ]; then
      _joined="$_joined $_c"
    else
      _joined="$_c"
    fi
  done
  {
    printf '#compdef nucleus-\n'
    printf '\n'
    printf '# GENERATED by src/scripts/completions/gen-completions.sh — do not edit.\n'
    printf '\n'
    printf 'local -a _nucleus_commands\n'
    printf '_nucleus_commands=(%s)\n' "$_joined"
    printf '%s\n' "_describe -t commands 'nucleus command' _nucleus_commands"
  } >"$_tmp_file"
  mv -f "$_tmp_file" "$_out_file"
}

# generate_all <out-dir> — generate every command file plus the dispatcher.
generate_all() {
  local _out_dir="$1"
  mkdir -p "$_out_dir"
  local _cmd
  for _cmd in "${COMMANDS[@]}"; do
    generate_command_file "$_cmd" "$_out_dir"
  done
  generate_dispatcher "$_out_dir"
}

_check_mode=0
case "${1:-}" in
--help | -h)
  usage
  exit 0
  ;;
--check)
  _check_mode=1
  ;;
generate | "")
  _check_mode=0
  ;;
*)
  error "unknown argument '$1'"
  usage >&2
  exit 1
  ;;
esac

if [ "$_check_mode" -eq 1 ]; then
  _check_tmp="$(mktemp -d)"
  trap 'rm -rf "$_check_tmp"' EXIT
  generate_all "$_check_tmp"
  _diff_found=0
  _check_name=""
  for _check_name in "$_check_tmp"/*; do
    [ -f "$_check_name" ] || continue
    _check_name="$(basename "$_check_name")"
    if [ ! -f "$COMPLETIONS_DIR/$_check_name" ] || ! cmp -s "$_check_tmp/$_check_name" "$COMPLETIONS_DIR/$_check_name"; then
      warn "check: $COMPLETIONS_DIR/$_check_name differs from generated output — run src/scripts/completions/gen-completions.sh to regenerate"
      _diff_found=1
    fi
  done
  for _check_name in "$COMPLETIONS_DIR"/_nucleus*; do
    [ -f "$_check_name" ] || continue
    _check_name="$(basename "$_check_name")"
    if [ ! -f "$_check_tmp/$_check_name" ]; then
      warn "check: $COMPLETIONS_DIR/$_check_name is not produced by the generator (hand-written or stale)"
      _diff_found=1
    fi
  done
  if [ "$_diff_found" -eq 1 ]; then
    error "generated completions are stale"
    exit 1
  fi
  say "check: all generated completion files match the tree."
  exit 0
fi

trap 'rm -f "$COMPLETIONS_DIR"/.tmp-_nucleus*' EXIT
generate_all "$COMPLETIONS_DIR"
say "generated $(( ${#COMMANDS[@]} + 1 )) completion files in src/modules/completions/zsh"
