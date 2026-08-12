# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

_REPOSITORY_POLICY_STEP_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPOSITORY_POLICY_STEP_SH="$(basename "${BASH_SOURCE[0]}")"
_REPOSITORY_POLICY_STEP_PS1="${_REPOSITORY_POLICY_STEP_SH%.sh}.ps1"
_REPOSITORY_POLICY_STEP_ID="${_REPOSITORY_POLICY_STEP_SH#[0-9][0-9]-}"
_REPOSITORY_POLICY_STEP_ID="${_REPOSITORY_POLICY_STEP_ID%.sh}"
readonly _REPOSITORY_POLICY_STEP_DIR _REPOSITORY_POLICY_STEP_SH _REPOSITORY_POLICY_STEP_PS1 _REPOSITORY_POLICY_STEP_ID

register_step "repository-policy" "Repository policy" run_repository_policy

run_repository_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  local _failed=0

  say "--- config method compliance ---"
  run_config_method_compliance "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- activation token placeholder ---"
  run_activation_token_placeholder "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- preflight install command policy ---"
  run_preflight_install_command_policy "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- embedded content enforcement ---"
  run_embedded_content_enforcement "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- agents policy ---"
  run_agents_policy "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- no real-user test coupling ---"
  run_no_real_user_test_coupling "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- dummy key uniformity ---"
  run_dummy_key_uniformity "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  if [ "$_failed" -ne 0 ]; then
    error "repository policy check failed"
    return 1
  fi
  say "repository policy passed."
  return 0
}

run_config_method_compliance() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _cfg_errors=0
  local _cfg_dir="src/modules/configs"
  local _cfg_par_tmpdir
  _cfg_par_tmpdir=$(mktemp -d) || {
    error "failed to create temp dir"
    _cfg_errors=$((_cfg_errors + 1))
  }

  # Single-pass: collect all config file basenames, run one grep across src/
  local _cfg_patterns
  _cfg_patterns=$(mktemp) || {
    error "failed to create temp file"
    _cfg_errors=$((_cfg_errors + 1))
  }
  find "$_cfg_dir" -type f -exec basename {} \; | sort -u >"$_cfg_patterns"
  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns
  find src/ \( -name '*.nix' -o -name '*.ps1' -o -name '*.sh' \) -not -path '*/vendor/*' -not -path '*/configs/*' -print |
    filter_gitignored |
    xargs grep -n -F -f "$_cfg_patterns" 2>/dev/null ||
    true # check-suppress:suppression_doc: xargs grep exits 1 when no config basename collisions are found; no match is the expected state
  rm -f "$_cfg_patterns"

  # Check for configs. method usage
  # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
  find "$_cfg_dir" -type f -print0 |
    xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
      _tmpdir="$1"
      _f="$2"
      _basename=$(basename "$_f")
      # Skip infrastructure files and Nix modules inside configs/  # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
      case "$_basename" in
        .gitkeep|.gitignore|*.schema.json) exit 0 ;;
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
    done <"$_result_file"
  done
  rm -rf -- "$_cfg_par_tmpdir"

  if [ "$_cfg_errors" -gt 0 ]; then
    error "config method compliance check failed with $_cfg_errors error(s)"
    return 1
  fi
  say "config method compliance passed."
  return 0
}

run_activation_token_placeholder() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _act_temp
  _act_temp="$(mktemp)" || {
    error "failed to create temp file"
    return 1
  }

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in *.sh | *.zsh) printf '%s\0' "$_f" ;; esac
    done | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null >"$_act_temp" || true # check-suppress:suppression_doc: grep exits 1 when no token placeholders are found; an empty result file is the clean state
  else
    find src/scripts -type f \( -name '*.sh' -o -name '*.zsh' \) -print0 |
      xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null >"$_act_temp" || true # check-suppress:suppression_doc: grep exits 1 when no token placeholders are found; an empty result file is the clean state
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

run_preflight_install_command_policy() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _errors=0
  # Exclude this check's own sibling file: its source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; self-refs are dynamic
  local _self_ps1="$_REPOSITORY_POLICY_STEP_PS1"

  # Collect PowerShell files
  local _ps1_files=()
  if $_has_args; then
    if [ ${#PS1_FILES[@]} -gt 0 ]; then
      # Drop this check's own sibling file from the scoped set
      for _f in "${PS1_FILES[@]}"; do
        [ "$(basename "$_f")" = "$_self_ps1" ] || _ps1_files+=("$_f")
      done
    fi
  else
    # Find all .ps1 files outside vendor/ and this check's own sibling
    while IFS= read -r -d '' _f; do
      _ps1_files+=("$_f")
    done < <(find . -name '*.ps1' -not -name "$_self_ps1" -not -path './vendor/*' -not -path './.git/*' -print0)
    # Apply gitignore filter as a second pass (find -print0 uses null separators,
    # which filter_gitignored doesn't support directly)
    mapfile -t _ps1_files < <(printf '%s\n' "${_ps1_files[@]}" | filter_gitignored)
  fi

  if [ "${#_ps1_files[@]}" -gt 0 ]; then
    local _tmpdir
    _tmpdir=$(mktemp -d) || {
      error "failed to create temp dir"
      _errors=$((_errors + 1))
    }

    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_ps1_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _f="$2"
        _out="$1/$(echo "$_f" | tr "/" "_").out"
        grep -Hn "Assert-ToolAvailable.*-InstallCommand" "$_f" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: grep exits 1 when a file has no InstallCommand matches; an empty .out file is the clean state
      ' _ "$_tmpdir"

    local _f _err
    for _f in "$_tmpdir"/*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _errors=$((_errors + 1))
        error "$_err"
      done <"$_f"
    done

    rm -rf -- "$_tmpdir"

    if [ "$_errors" -gt 0 ]; then
      say "  Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
      return 1
    fi
  fi

  say "no preflight InstallCommand violations found."
  return 0
}

run_embedded_content_enforcement() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _errors=0
  # Exclude this check's own file: its source contains the literal heredoc-detection patterns.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _self_sh="$_REPOSITORY_POLICY_STEP_SH"

  # Embedded-content policy scope for POSIX: src/scripts/** (see .agents/instructions/embedded-content.instructions.md).
  local _sh_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
      src/scripts/*.sh) [ "$(basename "$_f")" = "$_self_sh" ] || _sh_files+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _sh_files+=("$_f")
    done < <(find src/scripts -type f -name '*.sh' -not -name "$_self_sh" -print0)
    mapfile -t _sh_files < <(printf '%s\n' "${_sh_files[@]}" | filter_gitignored)
  fi

  if [ "${#_sh_files[@]}" -gt 0 ]; then
    # Heredoc detector lives in a sibling .awk file (shellcheck policy: extract awk programs >10 lines).
    local _awk_path="$_REPOSITORY_POLICY_STEP_DIR/$_REPOSITORY_POLICY_STEP_ID.awk"

    local _violation
    while IFS= read -r _violation; do
      _errors=$((_errors + 1))
      error "$_violation"
    done < <(awk -f "$_awk_path" "${_sh_files[@]}")
  fi

  if [ "$_errors" -gt 0 ]; then
    say "  Extract heredocs above 30 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    return 1
  fi

  say "no embedded-content heredoc violations found."
  return 0
}

_strip_prompt_frontmatter() {
  awk 'BEGIN{fm=0} /^---$/ {fm++; if (fm == 1) next; if (fm == 2) {fm = 3; next}} fm == 1 || fm == 2 {next} {print}' "$1"
}

run_agents_policy() {
  local _repo_root="$2"
  cd "$_repo_root" || return 1
  local _agents_errors=0

  local _repo_commit_staged=".agents/prompts/commit-staged.prompt.md"
  local _user_commit_staged="src/users/default/agents/prompts/commit-staged.prompt.md"
  local _repo_body _user_body
  _repo_body=$(_strip_prompt_frontmatter "$_repo_commit_staged")
  _user_body=$(_strip_prompt_frontmatter "$_user_commit_staged")
  if [ "$_repo_body" != "$_user_body" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "commit-staged.prompt.md body mismatch between repo and user overlay"
  else
    say "commit-staged prompt bodies match."
  fi

  local _instr
  while IFS= read -r -d '' _instr; do
    if ! awk 'NR==1 && $0=="---" {found=1; exit} END{exit !found}' "$_instr"; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing YAML frontmatter opener"
      continue
    fi
    local _desc _name _apply
    _desc=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    _name=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    _apply=$(awk '/^---$/{n++; next} n==1 && /^applyTo:/{sub(/^applyTo: */, ""); gsub(/^"|"$/, ""); print; exit}' "$_instr")
    if [[ ! "$_desc" =~ ^Use\ when ]]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: description must start with \"Use when\""
    fi
    if [ -z "$_name" ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing name frontmatter field"
    fi
    if [ -z "$_apply" ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: missing applyTo frontmatter field"
    elif [ "$_apply" = '**' ]; then
      _agents_errors=$((_agents_errors + 1))
      error "${_instr#./}: applyTo must not be \"**\" — use scripts/**, src/**, tests/** or narrower"
    fi
  done < <(find .agents/instructions -type f -name '*.instructions.md' -print0)

  local _agents_md="AGENTS.md"
  local _missing_link
  _missing_link=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }
  grep -oE '\.agents/instructions/[a-z0-9-]+\.instructions\.md' "$_agents_md" 2>/dev/null |
    sort -u |
    while IFS= read -r _link; do
      [ -f "$_link" ] || echo "$_link"
    done >"$_missing_link" || true # check-suppress:suppression_doc: grep exits 1 when AGENTS.md has no instruction links; empty missing-link file is valid
  if [ -s "$_missing_link" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "AGENTS.md references missing instruction files:"
    while IFS= read -r _line; do
      error "  $_line"
    done <"$_missing_link"
  else
    say "AGENTS.md instruction links resolve."
  fi
  rm -f "$_missing_link"

  if [ "$_agents_errors" -gt 0 ]; then
    error "agents policy check failed with $_agents_errors error(s)"
    return 1
  fi
  say "agents policy passed."
  return 0
}

# ref: testing.instructions.md (No real-user test coupling)
run_no_real_user_test_coupling() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  cd "$_repo_root" || return 1
  local _users_root="src/users"
  local _errors=0
  local _user _hit

  for _user_path in "$_users_root"/*/; do
    [ -d "$_user_path" ] || continue
    _user="$(basename "$_user_path")"
    [ "$_user" = default ] && continue
    while IFS= read -r _hit; do
      [ -z "$_hit" ] && continue
      _errors=$((_errors + 1))
      error "tests must not reference production user '$_user': $_hit (see testing.instructions.md: No real-user test coupling)"
    done < <(grep -rn -w "$_user" tests 2>/dev/null || true) # check-suppress:suppression_doc: grep exits 1 when no matches; zero hits is the expected state
  done

  if [ "$_errors" -gt 0 ]; then
    error "no real-user test coupling check failed with $_errors error(s)"
    return 1
  fi
  say "no real-user test coupling policy passed."
  return 0
}

run_dummy_key_uniformity() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _dummy_registry="src/modules/dummy-keys.json"
  local _dummy_errors=0
  local _dummy_registered _dummy_hits _dummy_files=()
  local _file _rest _line _lit _f

  # Rule: every hardcoded sk- style API key literal (sk-[A-Za-z0-9]{4,}) in tracked files must be a registered dummyKeys value.
  _dummy_registered=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }
  _dummy_hits=$(mktemp) || {
    error "failed to create temp file"
    rm -f "$_dummy_registered"
    return 1
  }
  if [ ! -f "$_dummy_registry" ]; then
    error "dummy-key registry not found at $_dummy_registry"
    rm -f "$_dummy_registered" "$_dummy_hits"
    return 1
  fi
  jq -r '.dummyKeys[].value' "$_dummy_registry" >"$_dummy_registered" 2>/dev/null || {
    error "failed to read dummy-key registry $_dummy_registry"
    rm -f "$_dummy_registered" "$_dummy_hits"
    return 1
  }

  # Exclude this check's own files: their source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _dummy_self_sh="$_REPOSITORY_POLICY_STEP_SH" _dummy_self_ps1="$_REPOSITORY_POLICY_STEP_PS1"

  if $_has_args; then
    for _f in "${_files[@]}"; do
      # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; secrets/vendor/fixtures are separate concerns and schema prose documents the value format
      case "$_f" in
      src/secrets/* | vendor/* | tests/fixtures/* | *.schema.json) continue ;;
      esac
      case "$(basename "$_f")" in
      "$_dummy_self_sh" | "$_dummy_self_ps1") continue ;;
      esac
      _dummy_files+=("$_f")
    done
  else
    # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; secrets/vendor/fixtures are separate concerns
    mapfile -t _dummy_files < <(
      git ls-files |
        filter_gitignored |
        grep -v -E '^(src/secrets/|vendor/|tests/fixtures/)' |
        grep -v '\.schema\.json$' |
        grep -v -E "(^|/)$_dummy_self_sh$|(^|/)$_dummy_self_ps1$"
    )
  fi

  if [ "${#_dummy_files[@]}" -gt 0 ]; then
    printf '%s\0' "${_dummy_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" grep -HnoE '\bsk-[A-Za-z0-9-]{4,}' 2>/dev/null >"$_dummy_hits" ||
      true # check-suppress:suppression_doc: grep exits 1 when no sk- API key literals are found; zero hits is the expected state

    while IFS= read -r _hit; do
      [ -z "$_hit" ] && continue
      _file="${_hit%%:*}"
      _rest="${_hit#*:}"
      _line="${_rest%%:*}"
      _lit="${_rest#*:}"
      if grep -Fxq "$_lit" "$_dummy_registered"; then
        continue
      fi
      _dummy_errors=$((_dummy_errors + 1))
      error "unregistered dummy API key literal '$_lit' at $_file:$_line (register it in src/modules/dummy-keys.json or use a registered value)"
    done <"$_dummy_hits"
  fi

  rm -f "$_dummy_registered" "$_dummy_hits"

  if [ "$_dummy_errors" -gt 0 ]; then
    error "dummy key uniformity check failed with $_dummy_errors error(s)"
    return 1
  fi
  say "dummy key uniformity policy passed."
  return 0
}
