# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"
bash_guard_require 5 1 check

_cf_now_ms() {
  if declare -F _step_now_ms >/dev/null 2>&1; then
    _step_now_ms
  elif [ -n "${EPOCHREALTIME-}" ]; then
    awk -v t="$EPOCHREALTIME" 'BEGIN { printf "%d\n", int(t * 1000) }'
  else
    perl -MTime::HiRes=time -e 'printf "%d\n", int(time() * 1000)' 2>/dev/null || date +%s000
  fi
}

_cf_dur_s() {
  local _ms="${1:-0}"
  if declare -F _format_duration_s >/dev/null 2>&1; then
    _format_duration_s "$_ms"
  else
    awk -v ms="$_ms" 'BEGIN { printf "%.3f s", ms / 1000 }'
  fi
}

# The canonical nucleus-* command set comes from the committed manifest.
# The zsh side asserts coverage over the full manifest; the pwsh side asserts
# completer and flag inventory parity for commands that have a Windows app
# surface (profile.ps1). The nix-capable check path separately proves the
# manifest matches mkNucleusApps.
_load_nucleus_commands_from_manifest() {
  local _root="${1:-$_repo_root}"
  local _manifest="$_root/src/modules/completions/nucleus-apps.json"
  require_command jq "jq is required to read the nucleus command manifest"
  [ -f "$_manifest" ] || {
    error "nucleus command manifest not found: $_manifest"
    return 1
  }
  _NUCLEUS_COMMANDS=()
  local _n10
  while IFS= read -r _n10; do
    [ -n "$_n10" ] || continue
    _NUCLEUS_COMMANDS+=("$_n10")
  done < <(jq -r '.commands[]' "$_manifest")
  [ "${#_NUCLEUS_COMMANDS[@]}" -gt 0 ] || {
    error "nucleus command manifest contains no commands: $_manifest"
    return 1
  }
  _NUCLEUS_PWSH_COMMANDS=()
  for _n10 in "${_NUCLEUS_COMMANDS[@]}"; do
    case "$_n10" in
    camilladsp-heartbeat) continue ;;
    esac
    _NUCLEUS_PWSH_COMMANDS+=("$_n10")
  done
}

# On nix-capable hosts, the committed manifest must equal its flake derivation.
_check_manifest_matches_flake() {
  local _root="${1:-$_repo_root}"
  local _manifest _out
  _manifest="$_root/src/modules/completions/nucleus-apps.json"
  _out="$(nucleus_nix_locked nix build --no-link --print-out-paths "$_root/src#nucleus-apps")" || return 1
  if ! cmp -s "$_out" "$_manifest"; then
    error "src/modules/completions/nucleus-apps.json is stale — regenerate it from ./src#nucleus-apps"
    return 1
  fi
  say "nucleus app manifest matches its flake derivation."
}

# pascal_case <cmd> yields the $nucleus<Cmd>Flags spelling gen-completions.ps1 emits.
pascal_case() {
  printf '%s' "$1" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }'
}

# The command's .sh help source. check-pwsh has no .sh twin, so nothing to introspect.
sh_for_command() {
  case "$1" in
  *) printf '%s\n' "scripts/$1.sh" ;;
  esac
}

register_step "completions-fresh" "Completions freshness (generated files match)" run_completions_fresh posix full nix
register_step_tools "completions-fresh" "nix pwsh jq python3"

_cf_na_manifest_result_file() {
  local _ctx_name="$1"
  local -n _ctx="$1"
  printf '%s/nucleus-apps-manifest.result' "${_ctx[_wave_tmpdir]:-}"
}

_cf_na_manifest_lock_dir() {
  local _ctx_name="$1"
  local -n _ctx="$1"
  printf '%s/nucleus-apps-manifest.lock' "${_ctx[_wave_tmpdir]:-}"
}

_cf_na_manifest_write_result() {
  local _file="$1" _status="$2" _out="${3-}"
  {
    printf 'status=%s\n' "$_status"
    printf 'out=%s\n' "$_out"
  } >"${_file}.tmp.$$" && mv -f "${_file}.tmp.$$" "$_file"
}

_cf_na_manifest_read_result() {
  local _file="$1" _status_var="$2" _out_var="$3"
  local -n _st="$2" _op="$3"
  _st="" _op=""
  [ -f "$_file" ] || return 1
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
    status=*) _st="${_line#status=}" ;;
    out=*) _op="${_line#out=}" ;;
    esac
  done <"$_file"
  [ -n "$_st" ]
}

_cf_na_manifest_check() {
  # Returns shared/built nucleus-apps manifest status for this check run.
  # args: ctx_name status_var out_var state_var repo_root
  local _ctx_name="$1" _status_var="$2" _out_var="$3" _state_var="$4" _root="$5"
  local -n _ctx="$1" _mstatus="$2" _mout="$3" _mstate="$4"
  local _result _lock _manifest
  _result="$(_cf_na_manifest_result_file "$_ctx_name")"
  _lock="$(_cf_na_manifest_lock_dir "$_ctx_name")"
  _manifest="$_root/src/modules/completions/nucleus-apps.json"
  _mstatus="" _mout="" _mstate=built

  if [ -n "$_result" ] && _cf_na_manifest_read_result "$_result" "$_status_var" "$_out_var"; then
    _mstate=reused
    return 0
  fi
  if [ -n "$_lock" ] && mkdir "$_lock" 2>/dev/null; then
    if [ -n "$_result" ] && _cf_na_manifest_read_result "$_result" "$_status_var" "$_out_var"; then
      _mstate=reused
      rmdir "$_lock" 2>/dev/null || true # check-suppress:suppression_doc: best-effort release of shared nucleus-apps manifest lock
      return 0
    fi
    if _mout="$(nucleus_nix_locked nix build --no-link --print-out-paths "$_root/src#nucleus-apps")"; then
      if cmp -s "$_mout" "$_manifest"; then
        _mstatus=ok
      else
        _mstatus=stale
      fi
    else
      _mstatus=build_failed
      _mout=""
    fi
    [ -n "$_result" ] && _cf_na_manifest_write_result "$_result" "$_mstatus" "$_mout"
    rmdir "$_lock" 2>/dev/null || true # check-suppress:suppression_doc: best-effort release of shared nucleus-apps manifest lock
    _mstate=built
    return 0
  fi
  local _i=0
  while [ "$_i" -lt 600 ]; do
    if [ -n "$_result" ] && _cf_na_manifest_read_result "$_result" "$_status_var" "$_out_var"; then
      _mstate=reused
      return 0
    fi
    sleep 0.1 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  _mstate=built
  _check_manifest_matches_flake "$_root"
  local _rc=$?
  if [ "$_rc" -eq 0 ]; then
    _mstatus=ok
  else
    _mstatus=failed
  fi
  return "$_rc"
}

run_completions_fresh() {
  local -n ctx="$1"
  local _ctx_name="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1

  _load_nucleus_commands_from_manifest "$_repo_root" || return 1
  local _cf_na_t0 _cf_na_state=checked _cf_na_status="" _cf_na_out="" _cf_na_rc=0
  _cf_na_t0=$(_cf_now_ms)
  # D1: share/reuse the nucleus-apps build+compare result across steps in the
  # same full check run, preserving the check and freshness guarantee.
  _cf_na_manifest_check "$_ctx_name" _cf_na_status _cf_na_out _cf_na_state "$_repo_root" || _cf_na_rc=$?
  if [ "$_cf_na_rc" -eq 0 ]; then
    case "$_cf_na_status" in
    ok)
      # Preserve step 10's success/freshness message in both built and reused paths.
      say "nucleus app manifest matches its flake derivation."
      ;;
    stale)
      error "src/modules/completions/nucleus-apps.json is stale — regenerate it from ./src#nucleus-apps"
      return 1
      ;;
    build_failed)
      error "failed to build ./src#nucleus-apps for the generated-artifact check"
      return 1
      ;;
    *)
      return 1
      ;;
    esac
  else
    # _check_manifest_matches_flake already reported the failure in the fallback path.
    return 1
  fi
  say "completions-fresh: nucleus-apps manifest build+cmp: $(_cf_dur_s $(($(_cf_now_ms) - _cf_na_t0))) ($_cf_na_state)"

  # 1. Generated files must match generator output; drift is a hard failure.
  local _cf_gen_t0
  _cf_gen_t0=$(_cf_now_ms)
  if ! bash "$_repo_root/src/scripts/completions/gen-completions.sh" --check; then
    error "generated completions are stale — run src/scripts/completions/gen-completions.sh to regenerate"
    return 1
  fi
  say "completions-fresh: gen-completions.sh --check: $(_cf_dur_s $(($(_cf_now_ms) - _cf_gen_t0)))"

  # 2. Every command needs a zsh completion file, a pwsh completer entry and a
  #    defined flag inventory, so a new command cannot silently lack completions.
  local _cf_inv_t0 _cmd _pascal _profile="$_repo_root/src/scripts/shell/profile.ps1"
  _cf_inv_t0=$(_cf_now_ms)
  for _cmd in "${_NUCLEUS_COMMANDS[@]}"; do
    if [ ! -f "$_repo_root/src/modules/completions/zsh/_nucleus-$_cmd" ]; then
      error "missing zsh completion file src/modules/completions/zsh/_nucleus-$_cmd"
      return 1
    fi
  done
  for _cmd in "${_NUCLEUS_PWSH_COMMANDS[@]}"; do
    # Anchored at the line start: the command name alone also matches a comment
    # or a longer command (nucleus-svc inside nucleus-service-watchdog).
    if ! grep -qE "^Register-ArgumentCompleter -CommandName nucleus-$_cmd([[:space:]]|$)" "$_profile"; then
      error "missing pwsh completer entry for nucleus-$_cmd in src/scripts/shell/profile.ps1"
      return 1
    fi
    # WHY require the DEFINITION: the completer body names the same variable, so
    # a match anywhere in the file went green while nothing defined it.
    _pascal="$(pascal_case "$_cmd")"
    if ! grep -qE "^[$]nucleus${_pascal}Flags[[:space:]]*=" "$_profile"; then
      error "missing pwsh flag inventory \$nucleus${_pascal}Flags for nucleus-$_cmd in src/scripts/shell/profile.ps1"
      return 1
    fi
  done

  # 2b. Every referenced flag inventory must be defined: the generated region is
  #     the only definition site, so a completer naming an unemitted variable
  #     completes nothing.
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
  say "completions-fresh: inventory checks: $(_cf_dur_s $(($(_cf_now_ms) - _cf_inv_t0)))"

  # 3. A --list-* flag wired via _call_program must exist in --help, because
  #    completion values come from the live CLI.
  local _cf_int_t0 _sh_rel="" _zsh_file="" _help_tmp="" _list_flags="" _flag=""
  _cf_int_t0=$(_cf_now_ms)
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
  say "completions-fresh: help/--list-* introspection: $(_cf_dur_s $(($(_cf_now_ms) - _cf_int_t0)))"

  # 3b. Provider commands must exit 0 (E5). Test against repo scripts (not
  #     installed binaries, which may be stale in dev). For context-dependent
  #     providers ($words/variables), substitute a safe concrete value.
  local _cf_prov_t0 _prov_cmd="" _prov_test="" _prov_svc="" _prov_bin="" _prov_script=""
  _cf_prov_t0=$(_cf_now_ms)
  for _cmd in "${_NUCLEUS_COMMANDS[@]}"; do
    _zsh_file="$_repo_root/src/modules/completions/zsh/_nucleus-$_cmd"
    [ -f "$_zsh_file" ] || continue
    while IFS= read -r _prov_cmd; do
      [ -n "$_prov_cmd" ] || continue
      _prov_test="$_prov_cmd"
      # Map leading nucleus-<name> to repo script for dev/check correctness.
      _prov_bin="${_prov_test%%[[:space:]]*}"
      if [[ "$_prov_bin" == nucleus-* ]]; then
        _prov_script="$(sh_for_command "${_prov_bin#nucleus-}")"
        if [ -n "$_prov_script" ] && [ -f "$_repo_root/$_prov_script" ]; then
          _prov_test="bash $(printf '%q' "$_repo_root/$_prov_script")${_prov_test#"$_prov_bin"}"
        fi
      fi
      # endpoints provider needs a service with network endpoints
      # shellcheck disable=SC2016 # reason: matching literal $words placeholder from completion wiring
      if printf '%s' "$_prov_test" | grep -qF '$words'; then
        if printf '%s' "$_prov_test" | grep -q 'endpoint --list-endpoints'; then
          _prov_svc=""
          while IFS= read -r _s; do
            [ -n "$_s" ] || continue
            if bash "$_repo_root/scripts/svc.sh" endpoint --list-endpoints "$_s" >/dev/null 2>&1; then
              _prov_svc="$_s"
              break
            fi
          done < <(bash "$_repo_root/scripts/svc.sh" --list-services 2>/dev/null || true) # check-suppress:suppression_doc: probe for a service with endpoints; absence means no endpoint provider context to test
          if [ -z "$_prov_svc" ]; then
            continue
          fi
          _prov_test="$(printf '%s' "$_prov_test" | sed "s/\"\$words\[2\]\"/$_prov_svc/g; s/\$words\[2\]/$_prov_svc/g")"
        else
          continue
        fi
      fi
      # Run the provider command; pipelines must succeed as a whole.
      # check-suppress:suppression_doc: provider command output is not user-facing here; failure is the signal
      if ! bash -c "$_prov_test" >/dev/null 2>&1; then
        error "nucleus-$_cmd: completion provider command exited non-zero: $_prov_test"
        return 1
      fi
    done < <(sed -n "s/.*_call_program '[^']*' //p" "$_zsh_file" | LC_ALL=C sort -u)
  done
  say "completions-fresh: provider commands: $(_cf_dur_s $(($(_cf_now_ms) - _cf_prov_t0)))"

  # 4. Bidirectional help<->spec drift: every --long-flag token in an app's
  #    --help must exist in the spec, and every spec long flag must appear in
  #    that help. Fail naming the app and flag.
  local _cf_drift_t0 _spec_file="$_repo_root/src/modules/completions/nucleus-cli-spec.json"
  _cf_drift_t0=$(_cf_now_ms)
  require_command python3 "python3 is required for help/spec drift checking"
  [ -f "$_spec_file" ] || {
    error "nucleus CLI spec not found: $_spec_file"
    return 1
  }
  local _drift_out="" _drift_rc=0
  _drift_out="$(
    python3 "$_repo_root/src/scripts/checks/check-steps/10-completions-fresh-drift.py" "$_repo_root" "$_spec_file"
  )" || _drift_rc=$?
  if [ "$_drift_rc" -ne 0 ]; then
    if [ -n "$_drift_out" ]; then
      while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        error "$_line"
      done <<<"$_drift_out"
    fi
    error "help/spec drift detected"
    return 1
  fi
  say "completions-fresh: help/spec drift: $(_cf_dur_s $(($(_cf_now_ms) - _cf_drift_t0)))"

  say "completions freshness passed."
  return 0
}
