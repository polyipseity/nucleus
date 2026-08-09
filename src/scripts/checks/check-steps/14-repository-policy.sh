# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

_REPOSITORY_POLICY_STEP_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPOSITORY_POLICY_STEP_SH="$(basename "${BASH_SOURCE[0]}")"
_REPOSITORY_POLICY_STEP_PS1="${_REPOSITORY_POLICY_STEP_SH%.sh}.ps1"
readonly _REPOSITORY_POLICY_STEP_DIR _REPOSITORY_POLICY_STEP_SH _REPOSITORY_POLICY_STEP_PS1

register_step "repository-policy" 14 "Repository policy" run_14_repository_policy

run_14_repository_policy() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  local _failed=0

  say "--- config method compliance ---"
  run_14_config_method_compliance "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- activation token placeholder ---"
  run_14_activation_token_placeholder "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- preflight install command policy ---"
  run_14_preflight_install_command_policy "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- embedded content enforcement ---"
  run_14_embedded_content_enforcement "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  say "--- agents policy ---"
  run_14_agents_policy "$_has_args" "$_repo_root" "${_files[@]}" || _failed=1

  if [ "$_failed" -ne 0 ]; then
    error "repository policy check failed"
    return 1
  fi
  say "repository policy passed."
  return 0
}

run_14_config_method_compliance() {
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

run_14_activation_token_placeholder() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _act_temp
  _act_temp="$(mktemp)" || { error "failed to create temp file"; return 1; }

  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in *.sh|*.zsh) printf '%s\0' "$_f" ;; esac
    done | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true  # check-suppress:suppression_doc: grep exits 1 when no token placeholders are found; an empty result file is the clean state
  else
    find src/scripts -type f \( -name '*.sh' -o -name '*.zsh' \) -print0 \
      | xargs -0 -P "$PARALLEL_JOBS" grep -Hn '^\s*#.*__[A-Z][A-Z_]*__' 2>/dev/null > "$_act_temp" || true  # check-suppress:suppression_doc: grep exits 1 when no token placeholders are found; an empty result file is the clean state
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

run_14_preflight_install_command_policy() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s21_errors=0
  # Exclude this check's own sibling file: its source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; self-refs are dynamic
  local _s21_self_ps1="$_REPOSITORY_POLICY_STEP_PS1"

  # Collect PowerShell files
  local _ps1_files=()
  if $_has_args; then
    if [ ${#PS1_FILES[@]} -gt 0 ]; then
      # Drop this check's own sibling file from the scoped set
      for _f in "${PS1_FILES[@]}"; do
        [ "$(basename "$_f")" = "$_s21_self_ps1" ] || _ps1_files+=("$_f")
      done
    fi
  else
    # Find all .ps1 files outside vendor/ and this check's own sibling
    while IFS= read -r -d '' _f; do
      _ps1_files+=("$_f")
    done < <(find . -name '*.ps1' -not -name "$_s21_self_ps1" -not -path './vendor/*' -not -path './.git/*' -print0)
    # Apply gitignore filter as a second pass (find -print0 uses null separators,
    # which filter_gitignored doesn't support directly)
    mapfile -t _ps1_files < <(printf '%s\n' "${_ps1_files[@]}" | filter_gitignored)
  fi

  if [ "${#_ps1_files[@]}" -gt 0 ]; then
    local _s21_tmpdir
    _s21_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _s21_errors=$((_s21_errors + 1)); }

    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_ps1_files[@]}" \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _f="$2"
        _out="$1/$(echo "$_f" | tr "/" "_").out"
        grep -Hn "Assert-ToolAvailable.*-InstallCommand" "$_f" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: grep exits 1 when a file has no InstallCommand matches; an empty .out file is the clean state
      ' _ "$_s21_tmpdir"

    local _f _err
    for _f in "$_s21_tmpdir"/*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _s21_errors=$((_s21_errors + 1))
        error "$_err"
      done < "$_f"
    done

    rm -rf -- "$_s21_tmpdir"

    if [ "$_s21_errors" -gt 0 ]; then
      say "  Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
      return 1
    fi
  fi

  say "no preflight InstallCommand violations found."
  return 0
}

run_14_embedded_content_enforcement() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s18_errors=0
  # Exclude this check's own file: its source contains the literal heredoc-detection patterns.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  local _s18_self_sh="$_REPOSITORY_POLICY_STEP_SH"

  # Embedded-content policy scope for POSIX: src/scripts/** (see .agents/instructions/embedded-content.instructions.md).
  local _sh_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
        src/scripts/*.sh) [ "$(basename "$_f")" = "$_s18_self_sh" ] || _sh_files+=("$_f") ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _sh_files+=("$_f")
    done < <(find src/scripts -type f -name '*.sh' -not -name "$_s18_self_sh" -print0)
    mapfile -t _sh_files < <(printf '%s\n' "${_sh_files[@]}" | filter_gitignored)
  fi

  if [ "${#_sh_files[@]}" -gt 0 ]; then
    # Heredoc detector lives in a sibling .awk file (shellcheck policy: extract awk programs >10 lines).
    local _s18_awk_path="$_REPOSITORY_POLICY_STEP_DIR/14-repository-policy.awk"

    local _s18_violation
    while IFS= read -r _s18_violation; do
      _s18_errors=$((_s18_errors + 1))
      error "$_s18_violation"
    done < <(awk -f "$_s18_awk_path" "${_sh_files[@]}")
  fi

  if [ "$_s18_errors" -gt 0 ]; then
    say "  Extract heredocs above 30 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    return 1
  fi

  say "no embedded-content heredoc violations found."
  return 0
}

_strip_prompt_frontmatter() {
  awk 'BEGIN{fm=0} /^---$/ {fm++; if (fm == 1) next; if (fm == 2) {fm = 3; next}} fm == 1 || fm == 2 {next} {print}' "$1"
}

run_14_agents_policy() {
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

  local _deleted_manifest=".agents/deleted-instructions.json"
  if [ ! -f "$_deleted_manifest" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "missing $_deleted_manifest"
  fi
  local _stale_pattern
  _stale_pattern=$(jq -r '.stems | map(. + ".instructions.md") | join("|")' "$_deleted_manifest")

  local _stale_hits
  _stale_hits=$(mktemp) || { error "failed to create temp file"; return 1; }
  grep -RIn -E "$_stale_pattern" \
    --exclude-dir='.git' \
    --exclude='14-repository-policy.sh' \
    --exclude='14-repository-policy.ps1' \
    --exclude='agents-policy-tests.sh' \
    --exclude='deleted-instructions.json' \
    . 2>/dev/null > "$_stale_hits" || true  # check-suppress:suppression_doc: grep exits 1 when no stale instruction references remain; empty output is the expected clean state
  if [ -s "$_stale_hits" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "stale .agents instruction references found:"
    while IFS= read -r _line; do
      error "  $_line"
    done < "$_stale_hits"
  else
    say "no stale .agents instruction references found."
  fi
  rm -f "$_stale_hits"

  local _agents_md="AGENTS.md"
  local _missing_link
  _missing_link=$(mktemp) || { error "failed to create temp file"; return 1; }
  grep -oE '\.agents/instructions/[a-z0-9-]+\.instructions\.md' "$_agents_md" 2>/dev/null \
    | sort -u \
    | while IFS= read -r _link; do
        [ -f "$_link" ] || echo "$_link"
      done > "$_missing_link" || true  # check-suppress:suppression_doc: grep exits 1 when AGENTS.md has no instruction links; empty missing-link file is valid
  if [ -s "$_missing_link" ]; then
    _agents_errors=$((_agents_errors + 1))
    error "AGENTS.md references missing instruction files:"
    while IFS= read -r _line; do
      error "  $_line"
    done < "$_missing_link"
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
