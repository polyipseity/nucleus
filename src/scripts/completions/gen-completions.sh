#!/usr/bin/env bash
# Generate zsh completions and PowerShell-facing artifacts from the committed CLI spec;
# the spec is the source of truth. Idempotent, and --check fails listing every
# differing checked-in file (check step 10-completions-fresh).
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
SPEC_FILE="$REPO_ROOT/src/modules/completions/nucleus-cli-spec.json"
NUCLEUS_APPS_MANIFEST="$REPO_ROOT/src/modules/completions/nucleus-apps.json"

require_command jq "jq is required to read the nucleus CLI spec"

usage() {
  usage_std "$(basename "$0")" "generate|--check|--help" "Generate zsh completion files for every nucleus-* command from src/modules/completions/nucleus-cli-spec.json. Default action: generate (write files in place). --check regenerates into a temp dir and fails (exit 1) listing every differing file. Files are generated — do not edit by hand."
}

# The canonical nucleus-* command set comes from the committed manifest.
# NUCLEUS_COMPLETIONS_COMMANDS overrides for tests (space/newline separated).
COMMANDS=()
if [ -n "${NUCLEUS_COMPLETIONS_COMMANDS:-}" ]; then
  while IFS= read -r _cmd; do
    [ -n "$_cmd" ] || continue
    case "$_cmd" in
    nucleus-*) COMMANDS+=("${_cmd#nucleus-}") ;;
    *) COMMANDS+=("$_cmd") ;;
    esac
  done < <(printf '%s\n' "$NUCLEUS_COMPLETIONS_COMMANDS" | tr ' \t' '\n' | LC_ALL=C sort -u)
else
  [ -f "$NUCLEUS_APPS_MANIFEST" ] || {
    error "nucleus command manifest not found: $NUCLEUS_APPS_MANIFEST"
    exit 1
  }
  while IFS= read -r _cmd; do
    [ -n "$_cmd" ] || continue
    COMMANDS+=("$_cmd")
  done < <(jq -r '.commands[]' "$NUCLEUS_APPS_MANIFEST")
fi
[ "${#COMMANDS[@]}" -gt 0 ] || {
  error "could not read nucleus command list"
  exit 1
}

# Spec is the source of truth; if unavailable in a fixture context, generate minimal completions.
if [ ! -f "$SPEC_FILE" ]; then
  SPEC_FILE=""
fi

# Escapes text for a generated single-quoted zsh spec word whose description is
# double-quoted and eval'd by _arguments. Escape \ " $ ` first, then ' as '\''.
escape_zsh_spec_text() {
  local _text
  # shellcheck disable=SC2016 # reason: regex metacharacter string for sed, not shell expansion.
  _text="$(printf '%s\n' "$1" | sed -E 's/([\\"$`])/\\\1/g')"
  printf '%s\n' "$_text" | sed -E "s/'/'\\\\''/g"
}

flag_desc() {
  local _long="$1" _desc="${2:-}"
  if [ -n "$_desc" ]; then
    printf '%s\n' "$_desc"
    return 0
  fi
  _long="${_long#--}"
  _long="${_long//-/' '}"
  printf '%s\n' "$_long"
}

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

# Append a line to a newline-delimited accumulator variable by name.
append_line() {
  local _var="$1" _line="$2"
  local -n _ref="$_var"
  if [ -n "$_ref" ]; then
    _ref="${_ref}"$'\n'"${_line}"
  else
    _ref="${_line}"
  fi
}

# emit_flag_spec <cmd> <flag-json> <out-var> <state-var> <state-action-var>
# Appends one _arguments spec line. Records dynamic state for value providers
# that need a state/action block (sections -> _call_program).
emit_flag_spec() {
  local _cmd="$1" _flag="$2" _out_var="$3" _state_var="$4" _action_var="$5"
  local _long _short _takes _vtype _source _desc _choices _spec _msg _action
  _long="$(jq -r '.long' <<<"$_flag")"
  _short="$(jq -r '.short // empty' <<<"$_flag")"
  _takes="$(jq -r '.takesValue' <<<"$_flag")"
  _vtype="$(jq -r '.valueType // "string"' <<<"$_flag")"
  _source="$(jq -r '.valueSource // empty' <<<"$_flag")"
  _desc="$(jq -r '.description // empty' <<<"$_flag")"
  _desc="$(flag_desc "$_long" "$_desc")"
  _desc="$(escape_zsh_spec_text "$_desc")"

  _msg="${_long#--}"
  _msg="${_msg//-/' '}"

  _spec=""
  # description and value completion
  if [ "$_takes" = "true" ]; then
    _action=""
    case "$_source" in
    sections)
      _action=":$_msg name:->sections"
      printf -v "$_state_var" '%s' "sections"
      printf -v "$_action_var" '%s' "_call_program 'sections' nucleus-$_cmd --list-sections"
      ;;
    services)
      _action=":$_msg name:_nucleus_svc_services"
      ;;
    verdicts)
      _choices="$(jq -r '(.choices // []) | join(" ")' <<<"$_flag")"
      if [ -n "$_choices" ]; then
        _action=":$_msg:($_choices)"
      else
        _action=":$_msg:"
      fi
      ;;
    profiles)
      _choices="$(jq -r '(.choices // []) | join(" ")' <<<"$_flag")"
      if [ -n "$_choices" ]; then
        _action=":$_msg:($_choices)"
      else
        _action=":$_msg:"
      fi
      ;;
    *)
      _choices="$(jq -r '(.choices // []) | join(" ")' <<<"$_flag")"
      if [ -n "$_choices" ]; then
        _action=":$_msg:($_choices)"
      elif [ "$_vtype" = "path" ]; then
        _action=":$_msg:_files"
      else
        _action=":$_msg:"
      fi
      ;;
    esac
    _spec="${_long}[${_desc}]${_action}"
  else
    _spec="${_long}[${_desc}]"
  fi

  if [ -n "$_short" ]; then
    # Emit grouped short+long exclusion where both exist: {-q,--quiet}'[desc]'
    # but keep action/simple form manageable; also emit short alias as separate spec
    # is less ideal. Use zsh grouped form for boolean flags without actions.
    if [ "$_takes" = "true" ]; then
      append_line "$_out_var" "'${_spec}'"
      append_line "$_out_var" "'${_short}[${_desc}]${_action}'"
    else
      append_line "$_out_var" "'{${_short},${_long}}[${_desc}]'"
    fi
  else
    append_line "$_out_var" "'${_spec}'"
  fi
}

# Determine if app needs subcommand-aware (stateful) completion.
app_needs_stateful() {
  local _app="$1"
  local _sc_count _has_sc_flags _has_values
  _sc_count="$(jq -r '.subcommands | length' <<<"$_app")"
  [ "$_sc_count" -eq 0 ] && return 1
  _has_sc_flags="$(jq -r '[.subcommands[] | (.flags | length) + (.positionals | length)] | add // 0' <<<"$_app")"
  _has_values="$(jq -r '[.subcommands[] | select(.values != null)] | length' <<<"$_app")"
  # Any per-subcommand flags, positionals, or values => stateful for correctness.
  if [ "$_has_sc_flags" -gt 0 ] || [ "$_has_values" -gt 0 ]; then
    return 0
  fi
  # Multiple subcommands with only names/descs: flat model is fine.
  return 1
}

# positional action snippet for a positional object
pos_action() {
  local _pos="$1" _idx="$2"
  local _name _source _choices _variadic _opt
  _name="$(jq -r '.name' <<<"$_pos")"
  _source="$(jq -r '.valueSource // empty' <<<"$_pos")"
  _choices="$(jq -r '(.choices // []) | join(" ")' <<<"$_pos")"
  _variadic="$(jq -r '.variadic // false' <<<"$_pos")"
  _opt=":${_name}:"
  case "$_source" in
  services) _opt=":${_name}:_nucleus_svc_services" ;;
  verdicts)
    [ -n "$_choices" ] && _opt=":${_name}:(${_choices})" || _opt=":${_name}:"
    ;;
  profiles)
    [ -n "$_choices" ] && _opt=":${_name}:(${_choices})" || _opt=":${_name}:"
    ;;
  sections) _opt=":${_name}:->sections" ;;
  *)
    [ -n "$_choices" ] && _opt=":${_name}:(${_choices})" || _opt=":${_name}:"
    ;;
  esac
  if [ "$_variadic" = "true" ]; then
    printf '*%s' "$_opt"
  else
    printf '%s%s' "$_idx" "$_opt"
  fi
}

generate_command_file() {
  local _cmd="$1" _out_dir="$2"
  local _out_file="$_out_dir/_nucleus-$_cmd"
  local _tmp_file="$_out_dir/.tmp-_nucleus-$_cmd.$$"
  local _app _global_specs="" _sub_names=() _s _desc _sub_line="" _sc
  local _stateful=0 _dyn_state="" _dyn_action="" _need_svc_glue=0

  if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
    _app="$(jq -c --arg n "$_cmd" '.apps[] | select(.name == $n)' "$SPEC_FILE")"
  else
    _app=""
  fi
  if [ -z "$_app" ] || [ "$_app" = "null" ]; then
    # Command in manifest but missing from spec: emit minimal help-only completion.
    _app='{"name":"'"$_cmd"'","summary":"","globalFlags":[],"subcommands":[]}'
  fi

  # Determine svc glue need.
  if [ "$_cmd" = "svc" ] || jq -e '.. | .valueSource? // empty | select(. == "services")' <<<"$_app" >/dev/null 2>&1; then
    _need_svc_glue=1
  fi

  # Global flags
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    local _gs="" _ds="" _da=""
    emit_flag_spec "$_cmd" "$_f" _gs _ds _da
    if [ -n "$_ds" ]; then
      _dyn_state="$_ds"
      _dyn_action="$_da"
    fi
    if [ -n "$_gs" ]; then append_line _global_specs "$_gs"; fi
  done < <(jq -c '.globalFlags[]?' <<<"$_app")

  # Subcommand names and descriptions
  while IFS= read -r _sc; do
    [ -n "$_sc" ] || continue
    _s="$(jq -r '.name' <<<"$_sc")"
    _desc="$(jq -r '.description // empty' <<<"$_sc")"
    _sub_names+=("$_s")
  done < <(jq -c '.subcommands[]?' <<<"$_app")

  if app_needs_stateful "$_app"; then
    _stateful=1
  fi

  {
    printf '#compdef nucleus-%s\n' "$_cmd"
    printf '\n'
    printf '# GENERATED by src/scripts/completions/gen-completions.sh — do not edit.\n'
    printf '\n'
    if [ "$_need_svc_glue" -eq 1 ]; then
      emit_svc_glue
      printf '\n'
    fi

    if [ "$_stateful" -eq 1 ]; then
      # Stateful: global flags + subcommand dispatch + per-subcommand args.
      printf '_arguments -C \\\n'
      printf "  '(-h --help)'{--help,-h}'[Show usage]'"
      # global flags (excluding help already emitted)
      local _gline
      while IFS= read -r _gline; do
        [ -n "$_gline" ] || continue
        # skip duplicate help if present as long flag only? globalFlags may include --help
        case "$_gline" in
        *"--help"*) continue ;;
        esac
        printf ' \\\n  %s' "$_gline"
      done <<<"$_global_specs"
      printf ' \\\n'
      printf '%s\n' "  '1:subcommand:->subcmd' \\"
      printf '%s\n\n' "  '*::arg:->args'"
      # shellcheck disable=SC2016 # reason: $state/$words are zsh variables in generated output, not shell expansions.
      printf 'case $state in\n'
      printf '  subcmd)\n'
      printf '    local -a _subcmds\n'
      printf '    _subcmds=(\n'
      while IFS= read -r _sc; do
        [ -n "$_sc" ] || continue
        _s="$(jq -r '.name' <<<"$_sc")"
        _desc="$(jq -r '.description // empty' <<<"$_sc")"
        _desc="$(escape_zsh_spec_text "$_desc")"
        printf "      '%s:%s'\n" "$_s" "$_desc"
      done < <(jq -c '.subcommands[]?' <<<"$_app")
      printf '    )\n'
      printf "    _describe -t commands 'subcommand' _subcmds\n"
      printf '    ;;\n'
      printf '  args)\n'
      # shellcheck disable=SC2016 # reason: $words is a zsh variable in generated output, not shell expansion.
      printf '    case $words[1] in\n'
      while IFS= read -r _sc; do
        [ -n "$_sc" ] || continue
        _s="$(jq -r '.name' <<<"$_sc")"
        printf '      %s)\n' "$_s"
        printf '        _arguments \\\n'
        # subcommand flags
        local _sc_specs="" _sc_ds="" _sc_da="" _sf
        while IFS= read -r _sf; do
          [ -n "$_sf" ] || continue
          emit_flag_spec "$_cmd" "$_sf" _sc_specs _sc_ds _sc_da
          if [ -n "$_sc_ds" ]; then
            _dyn_state="$_sc_ds"
            _dyn_action="$_sc_da"
          fi
        done < <(jq -c '.flags[]?' <<<"$_sc")
        # positionals
        local _pi=1 _p
        while IFS= read -r _p; do
          [ -n "$_p" ] || continue
          local _pa
          _pa="$(pos_action "$_p" "$_pi")"
          append_line _sc_specs "'${_pa}'"
          if jq -e '.variadic == true' <<<"$_p" >/dev/null 2>&1; then :; else _pi=$((_pi + 1)); fi
          # sections positional state
          if [ "$(jq -r '.valueSource // empty' <<<"$_p")" = "sections" ]; then
            _dyn_state="sections"
            _dyn_action="_call_program 'sections' nucleus-$_cmd --list-sections"
          fi
        done < <(jq -c '.positionals[]?' <<<"$_sc")
        if [ -z "$_sc_specs" ]; then
          printf "          '*: :'\n"
        else
          local _n=0 _i=0 _line
          _n="$(printf '%s\n' "$_sc_specs" | wc -l | tr -d ' ')"
          while IFS= read -r _line; do
            _i=$((_i + 1))
            if [ "$_i" -lt "$_n" ]; then
              printf '          %s \\\n' "$_line"
            else
              printf '          %s\n' "$_line"
            fi
          done <<<"$_sc_specs"
        fi
        printf '        ;;\n'
      done < <(jq -c '.subcommands[]?' <<<"$_app")
      printf '    esac\n'
      printf '    ;;\n'
      if [ -n "$_dyn_state" ] && [ -n "$_dyn_action" ]; then
        printf '  %s)\n' "$_dyn_state"
        printf '    %s\n' "$_dyn_action"
        printf '    ;;\n'
      fi
      printf 'esac\n'
    else
      # Flat completion (no per-subcommand flags/positionals).
      printf '_arguments \\\n'
      printf "  '(-h --help)'{--help,-h}'[Show usage]'"
      local _has_more=0
      [ "${#_sub_names[@]}" -gt 0 ] && _has_more=1
      [ -n "$_global_specs" ] && _has_more=1
      if [ "$_has_more" -eq 1 ]; then printf ' \\\n'; else printf '\n'; fi

      if [ "${#_sub_names[@]}" -gt 0 ]; then
        # build subcommand positional
        printf "  '1:subcommand:(("
        local _first=1
        while IFS= read -r _sc; do
          [ -n "$_sc" ] || continue
          _s="$(jq -r '.name' <<<"$_sc")"
          _desc="$(jq -r '.description // empty' <<<"$_sc")"
          _desc="$(escape_zsh_spec_text "$_desc")"
          if [ "$_first" -eq 1 ]; then
            printf "%s \"%s\"" "$_s" "$_desc"
            _first=0
          else
            printf " %s \"%s\"" "$_s" "$_desc"
          fi
        done < <(jq -c '.subcommands[]?' <<<"$_app")
        printf "))'"
        if [ -n "$_global_specs" ]; then printf ' \\\n'; else printf '\n'; fi
      fi
      if [ -n "$_global_specs" ]; then
        local _n=0 _i=0 _line
        _n="$(printf '%s\n' "$_global_specs" | wc -l | tr -d ' ')"
        while IFS= read -r _line; do
          [ -n "$_line" ] || continue
          _i=$((_i + 1))
          case "$_line" in *"--help"*)
            _n=$((_n - 1))
            continue
            ;;
          esac
        done <<<"$_global_specs"
        _i=0
        local _printed=0
        # recompute printable count
        _n=0
        while IFS= read -r _line; do
          [ -n "$_line" ] || continue
          case "$_line" in *"--help"*) continue ;; esac
          _n=$((_n + 1))
        done <<<"$_global_specs"
        while IFS= read -r _line; do
          [ -n "$_line" ] || continue
          case "$_line" in *"--help"*) continue ;; esac
          _i=$((_i + 1))
          if [ "$_i" -lt "$_n" ]; then
            printf '  %s \\\n' "$_line"
          else
            printf '  %s\n' "$_line"
          fi
        done <<<"$_global_specs"
      fi
      # dynamic state for flat model (e.g. unlikely, but handle sections)
      if [ -n "$_dyn_state" ] && [ -n "$_dyn_action" ]; then
        # shellcheck disable=SC2016 # reason: $state is a zsh variable in generated output, not shell expansion.
        printf 'case $state in\n'
        printf '%s)\n' "$_dyn_state"
        printf '  %s\n' "$_dyn_action"
        printf '  ;;\n'
        printf 'esac\n'
      fi
    fi
  } >"$_tmp_file"
  mv -f "$_tmp_file" "$_out_file"
}

generate_dispatcher() {
  local _out_dir="$1"
  local _out_file="$_out_dir/_nucleus"
  local _tmp_file="$_out_dir/.tmp-_nucleus.$$"
  local _joined="" _c
  for _c in "${COMMANDS[@]}"; do
    if [ -n "$_joined" ]; then _joined="$_joined $_c"; else _joined="$_c"; fi
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
--check) _check_mode=1 ;;
generate | "") _check_mode=0 ;;
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
say "generated $((${#COMMANDS[@]} + 1)) completion files in src/modules/completions/zsh"
