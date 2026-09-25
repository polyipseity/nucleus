#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "repo-policy-grep" "Repository policy (grep-heavy)" run_repo_policy_grep

# Sub-checks in output order, as "<label>|<function>|<style>".
_POLICY_GREP_CHECKS=(
  "store-path arg usage|run_store_path_arg_usage|ctx"
  "activation tool resolution|run_activation_tool_resolution|ctx"
  "package manager enforcement|run_package_manager_enforcement|ctx"
  "suppression audit|run_suppression_audit|ctx"
  "cloud-mount invariants|run_cloud_mount_invariants|ctx"
  "service supervision invariants|run_service_supervision_invariants|ctx"
)

run_repo_policy_grep() {
  local _ctx_name="$1"
  shift
  run_policy_checks "$_ctx_name" "repository policy (grep-heavy)" _POLICY_GREP_CHECKS "$@"
}

run_store_path_arg_usage() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

  # This step only applies to shell scripts.
  if $_has_args; then
    local _f _has_sh_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh)
        _has_sh_files=1
        break
        ;;
      esac
    done
    if [ "$_has_sh_files" -eq 0 ]; then
      say "0 shell files in scope — nothing to enforce."
      return 0
    fi
  fi

  # Collect candidate files: all .sh files under scripts/ and src/scripts/ (not
  # test fixtures, not check steps themselves).
  # ref: comment-annotations.instructions.md#C1 -- self-derived basenames for exclusion
  # shellcheck disable=SC2155 # reason: basename's exit status is irrelevant; self-derived for exclusion
  local _self_sh="$(basename "${BASH_SOURCE[0]}")"
  local _self_ps1="${_self_sh%.sh}.ps1"
  local _candidate_files=()

  # Files excluded from this check: their _X_bin variables are used as config
  # parameters (not commands), so the check would produce false positives.
  local _exclude_pattern='(check\.sh|'"$_self_sh"'|'"$_self_ps1"'|configure-gpg-agent\.sh)$'

  if $_has_args; then
    local _f
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh) _candidate_files+=("$_f") ;;
      esac
    done
    local _filtered=()
    for _f in "${_candidate_files[@]}"; do
      local _base
      _base="$(basename "$_f")"
      # Apply same exclusions as non-args branch (basename check + regex).
      case "$_base" in
      check.sh | "$_self_sh" | "$_self_ps1") continue ;;
      esac
      if echo "$_base" | grep -qE "$_exclude_pattern"; then
        continue
      fi
      _filtered+=("$_f")
    done
    _candidate_files=("${_filtered[@]}")
  else
    mapfile -t _candidate_files < <(
      find scripts/ src/scripts/ -name '*.sh' -print |
        filter_gitignored |
        grep -v -E "$_exclude_pattern"
    )
  fi

  if [ "${#_candidate_files[@]}" -eq 0 ]; then
    say "0 shell files in scope — nothing to enforce."
    return 0
  fi

  # Collect ALL .sh files for cross-file usage search (variables may be
  # exported and consumed in other scripts, e.g., _ds_gawk_bin).
  local _all_sh_files=()
  if $_has_args; then
    for _f in "${_candidate_files[@]}"; do
      _all_sh_files+=("$_f")
    done
  else
    mapfile -t _all_sh_files < <(
      find scripts/ src/scripts/ -name '*.sh' -print |
        filter_gitignored
    )
  fi

  # Phase 1: extract _X_bin="$N" declarations from candidate files.
  local _decls=()
  local _file
  for _file in "${_candidate_files[@]}"; do
    local _line
    while IFS= read -r _line; do
      _decls+=("$_line")
    done < <(grep -HnE '_[a-z][a-z0-9_]*_bin="\$[0-9]+"' "$_file" 2>/dev/null)
  done

  if [ "${#_decls[@]}" -eq 0 ]; then
    say "no store-path arg declarations found."
    return 0
  fi

  # Phase 2: for each declared variable, verify it has at least one command/PATH
  # usage across all shell scripts.
  local _decl _var _line_num
  for _decl in "${_decls[@]}"; do
    _file="${_decl%%:*}"
    _line_num="${_decl#*:}"
    _line_num="${_line_num%%:*}"
    _var="${_decl##*:}"
    _var="${_var%%=*}"
    _var="${_var#"${_var%%[![:space:]]*}"}"
    _var="${_var%"${_var##*[![:space:]]}"}"

    local _all_refs=0 _non_condition_refs=0
    local _search_file
    for _search_file in "${_all_sh_files[@]}"; do
      local _refs
      # check-suppress:suppression_doc: grep returns exit 1 on no match; || true allows empty result
      _refs=$(grep -n "\\\${${_var}\|\\\$${_var}" "$_search_file" 2>/dev/null ||
        true) # check-suppress:suppression_doc: grep returns exit 1 on no match; || true allows empty result
      [ -z "$_refs" ] && continue

      _all_refs=$((_all_refs + $(echo "$_refs" | wc -l)))

      local _filtered
      _filtered=$(echo "$_refs" |
        grep -v -E "^[0-9]+:[[:space:]]*_?[a-z_]*=\"\\\$[0-9]+\"" |
        grep -v -E "^[0-9]+:[[:space:]]*\[\[?\s+-[zn]\s" ||
        true) # check-suppress:suppression_doc: grep returns exit 1 when all lines are filtered; || true allows empty result
      # check-suppress:suppression_doc: grep -c returns exit 1 on zero matches; || true counts as 0
      _non_condition_refs=$((_non_condition_refs + $(echo "$_filtered" | grep -c . || true)))
    done

    if [ "$_all_refs" -eq 0 ]; then
      error "store-path arg variable ${_var} in ${_file} is declared but never referenced"
      _violations=$((_violations + 1))
    elif [ "$_non_condition_refs" -eq 0 ]; then
      error "store-path arg variable ${_var} in ${_file} is only used in condition checks, never as a command or PATH entry"
      _violations=$((_violations + 1))
    fi
  done

  if [ "$_violations" -eq 0 ]; then
    say "all store-path arg variables have command/PATH usage."
    return 0
  fi
  return 1
}

run_activation_tool_resolution() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

  # Only shell scripts apply to this check.
  if $_has_args; then
    local _f _has_sh_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh)
        _has_sh_files=1
        break
        ;;
      esac
    done
    if [ "$_has_sh_files" -eq 0 ]; then
      say "0 activation scripts in scope — nothing to resolve."
      return 0
    fi
  fi

  # Activation-script directories (subset of all scripts).
  local _activation_dirs=(
    src/scripts/packages src/scripts/shell src/scripts/agents
    src/scripts/secrets src/scripts/services src/scripts/vms
    src/scripts/configs src/scripts/editors src/scripts/integrations
    src/scripts/completions
  )

  # Collect candidate files: only activation-script directories.
  # ref: comment-annotations.instructions.md#C1 -- self-derived basename for self-exclusion
  # shellcheck disable=SC2155 # reason: basename's exit status is irrelevant; self-derived for exclusion
  local _self_sh="$(basename "${BASH_SOURCE[0]}")"
  local _candidate_files=()
  local _f

  if $_has_args; then
    local _dir
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh) ;;
      *) continue ;;
      esac
      for _dir in "${_activation_dirs[@]}"; do
        case "$_f" in
        "$_dir"/*)
          # shellcheck disable=SC2155 # reason: basename's exit status is irrelevant; exclusion check
          case "$(basename "$_f")" in
          "$_self_sh" | check.sh | android-fake-wifi-guest-*.sh) continue 2 ;;
          esac
          _candidate_files+=("$_f")
          break
          ;;
        esac
      done
    done
  else
    local _find_dirs=()
    for _dir in "${_activation_dirs[@]}"; do
      [ -d "$_dir" ] && _find_dirs+=("$_dir")
    done
    if [ "${#_find_dirs[@]}" -gt 0 ]; then
      mapfile -t _candidate_files < <(
        # shellcheck disable=SC2046 # reason: echo expands the find array safely — no globbing risk
        find "${_find_dirs[@]}" -name '*.sh' -print |
          filter_gitignored |
          grep -v -E '(check\.sh|android-fake-wifi-guest-|'"$_self_sh"')$'
      )
    fi
  fi

  if [ "${#_candidate_files[@]}" -eq 0 ]; then
    say "0 activation scripts in scope — nothing to resolve."
    return 0
  fi

  # --- Build dynamic allowlist of repo-defined functions ---
  local _lib_funcs_file
  _lib_funcs_file=$(mktemp)
  # shellcheck disable=SC2155 # reason: mktemp exit status checked below
  [ -f "$_lib_funcs_file" ] || {
    error "failed to create temp file for lib functions"
    return 1
  }
  {
    grep -rh -E '^[a-zA-Z_][a-zA-Z_0-9]*\(\)' src/scripts/lib/ 2>/dev/null |
      sed 's/[[:space:]]*().*//' | sort -u
    grep -rh -E '^function[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*' src/scripts/lib/ 2>/dev/null |
      sed 's/^function[[:space:]]*//' | sed 's/[[:space:]].*//' | sort -u
  } >"$_lib_funcs_file"

  # --- Awk scan ---
  local _awk_program
  # check-suppress:embedded-content: exception 1 (data-driven/generated) -- awk program for activation tool resolution
  read -r -d '' _awk_program <<'AWKEOF'
BEGIN {
  in_heredoc = 0
  heredoc_delim = ""
  case_depth = 0
  violations = 0

  split("set export local readonly declare if then else elif fi for while do done case esac function return exit trap shift source . eval exec cd pwd echo printf read test [ [[ true false break continue wait kill shopt type hash builtin command enable help let unset popd pushd dirs complete compgen compopt mapfile readarray caller times suspend", a)
  for (i in a) allow[a[i]] = 1;  delete a
  split("cat chmod chown cp date dd du env expand expr factor fmt fold head id install join link ln logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc od paste pathchk pinky pr printenv ptx readlink realpath rm rmdir sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort stat stty sum sync tac tail tee touch tr truncate tsort tty uname unexpand uniq unlink users vdir wc who whoami yes seq stdbuf", a)
  for (i in a) allow[a[i]] = 1;  delete a
  split("grep sed awk find xargs cut diff file which man basename dirname timeout sudo curl tar gzip gunzip chmod kill rm ln cp mv mkdir touch chmod killall lsof fuser env time mktemp", a)
  for (i in a) allow[a[i]] = 1;  delete a
  split("nix nix-env nix-build nix-channel nix-shell nix-store nix-collect-garbage nix-instantiate nix-prefetch-url nix-store nix-hash nixos-rebuild darwin-rebuild systemctl launchctl sw_vers xcode-select brew nix-shell nix-build git ssh scp rsync tar unzip zip make cmake cargo rustup rustc bun node npm npx python3 pip3 jq yq xmlstarlet xsltproc gawk getopt", a)
  for (i in a) allow[a[i]] = 1;  delete a
}

LIB_FUNCS_FILE != "" {
  while ((getline _lf < LIB_FUNCS_FILE) > 0) {
    if (_lf != "") allow[_lf] = 1
  }
  close(LIB_FUNCS_FILE)
}

/[^<]<<-?[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*([[:space:]].*$|^)/ || /^<<-?[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*([[:space:]].*$|^)/ {
  if (!in_heredoc) {
    line = $0
    if (match(line, /<<-?[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*/)) {
      heredoc_delim = substr(line, RSTART, RLENGTH)
      sub(/<<-?[[:space:]]*/, "", heredoc_delim)
      in_heredoc = 1
    }
    next
  }
}
in_heredoc {
  stripped = $0
  gsub(/^[[:space:]]+/, "", stripped)
  gsub(/[[:space:]]+$/, "", stripped)
  if (stripped == heredoc_delim) {
    in_heredoc = 0
    heredoc_delim = ""
  }
  next
}

/^[[:space:]]*(#|$)/ { next }

/^[[:space:]]*case[[:space:]]/ { case_depth++; next }
/^[[:space:]]*esac\b/ { if (case_depth > 0) case_depth--; next }
case_depth > 0 { next }

/^[[:space:]]*PATH=/ && !/^[[:space:]]*export[[:space:]]/ {
  line = $0
  sub(/^[[:space:]]*PATH="/, "", line)
  sub(/"[[:space:]]*$/, "", line)
  tmp = line
  while (match(tmp, /_[a-zA-Z][a-zA-Z_0-9]*_bin(_[a-zA-Z_0-9]+)?/)) {
    var_part = substr(tmp, RSTART, RLENGTH)
    sub(/_bin(_[a-zA-Z_0-9]+)?$/, "", var_part)
    sub(/^_/, "", var_part)
    n = split(var_part, parts, "_")
    if (n > 0 && parts[n] != "") {
      path_provided[parts[n]] = 1
    }
    tmp = substr(tmp, RSTART + RLENGTH)
  }
  next
}

/^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\(\)/ {
  fname = $0
  gsub(/^[[:space:]]+/, "", fname)
  sub(/[[:space:]]*\(\).*/, "", fname)
  if (fname != "") local_funcs[fname] = 1
  next
}
/^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\{/ {
  fname = $0
  gsub(/^[[:space:]]+/, "", fname)
  sub(/^function[[:space:]]+/, "", fname)
  sub(/[[:space:]]*\{.*/, "", fname)
  if (fname != "") local_funcs[fname] = 1
  next
}

/^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*[\+\-]?=/ { next }
/^[[:space:]]*["']/ { next }

{
  line = $0
  gsub(/^[[:space:]]+/, "", line)

  if (line ~ /^[{});]/ || line ~ /^;;/ || line ~ /^esac\b/ || line ~ /^fi\b/ ||
      line ~ /^done\b/ || line ~ /^then\b/ || line ~ /^else\b/ || line ~ /^do\b/) next

  match(line, /^[^[:space:];|&()]+/)
  if (RSTART == 0 || RLENGTH == 0) next
  cmd = substr(line, RSTART, RLENGTH)
  _cmd_end = RSTART + RLENGTH

  if (cmd == "if" || cmd == "while" || cmd == "until" || cmd == "elif") {
    rest = substr(line, _cmd_end)
    gsub(/^[[:space:]]+/, "", rest)
    if (substr(rest, 1, 1) == "!") {
      rest = substr(rest, 2)
      gsub(/^[[:space:]]+/, "", rest)
    }
    while (match(rest, /^[a-zA-Z_][a-zA-Z_0-9]*[\+\-]?=/)) {
      rest = substr(rest, RSTART + RLENGTH)
      gsub(/^[[:space:]]+/, "", rest)
    }
    if (substr(rest, 1, 1) == "\"" || substr(rest, 1, 1) == "'") next
    match(rest, /^[^[:space:];|&()]+/)
    if (RSTART == 0 || RLENGTH == 0) next
    cmd = substr(rest, RSTART, RLENGTH)
    next
  }

  if (cmd == "command" || cmd == "enable") {
    rest = substr(line, _cmd_end)
    gsub(/^[[:space:]]+/, "", rest)
    while (substr(rest, 1, 1) == "-") {
      match(rest, /^-[^[:space:]]+/)
      if (RSTART == 0) break
      rest = substr(rest, RSTART + RLENGTH)
      gsub(/^[[:space:]]+/, "", rest)
    }
    match(rest, /^[^[:space:];|&()]+/)
    if (RSTART == 0 || RLENGTH == 0) next
    cmd = substr(rest, RSTART, RLENGTH)
  }

  if (cmd ~ /^\//) next
  sub(/.*\//, "", cmd)
  if (cmd == "") next
  if (cmd == "{" || cmd == "}" || cmd == ")" || cmd == ";;" || cmd == "esac" ||
      cmd == "fi" || cmd == "done" || cmd == "then" || cmd == "else" || cmd == "do") next

  if (cmd !~ /^[a-z_][a-z0-9_-]*$/) next
  if (length(cmd) < 3) next

  if (cmd in allow) next
  if (cmd in path_provided) next
  if (cmd in local_funcs) next

  printf "%s:%d: bare external command \x27%s\x27 not resolved via store-path arg or PATH prepend\n", FILENAME, FNR, cmd
  violations++
}
END { exit (violations > 0) }
AWKEOF

  local _awk_violations
  _awk_violations=$(
    # shellcheck disable=SC2046 # reason: printf safely expands the array
    printf '%s\0' "${_candidate_files[@]}" |
      xargs -0 awk -v LIB_FUNCS_FILE="$_lib_funcs_file" "$_awk_program" 2>/dev/null
  )
  local _awk_exit=$?

  rm -f "$_lib_funcs_file"

  if [ "$_awk_exit" -ne 0 ] && [ -n "$_awk_violations" ]; then
    while IFS= read -r _violation; do
      [ -z "$_violation" ] && continue
      error "$_violation"
      _violations=$((_violations + 1))
    done <<<"$_awk_violations"
  fi

  if [ "$_violations" -gt 0 ]; then
    return 1
  fi
  say "all activation scripts use resolved tool paths."
  return 0
}

# Package manager usage enforcement: ban bare `pip install` and `npm install`.
# ref: allow-and-deny-lists.instructions.md#A1
run_package_manager_enforcement() {
  local -n ctx="$1"
  shift
  local _files=("$@")
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  cd "$_repo_root" || return 1
  local _violations=0

  # Skip when scoped to files outside this step's scope (no .sh/.ps1/.nix files).
  if $_has_args; then
    local _f _has_shell_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in *.sh | *.ps1 | *.nix)
        _has_shell_files=1
        break
        ;;
      esac
    done
    if [ "$_has_shell_files" -eq 0 ]; then
      say "0 shell files in scope — nothing to enforce."
      return 0
    fi
  fi

  # Ban bare `pip install` and `npm install`.
  local _grep_files=()
  # shellcheck disable=SC2178 # reason: nameref to context array — shellcheck sees string assignment but the ref resolves to an array
  local -n _sh_files="${ctx[SH_FILES]}"
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _ps1_files="${ctx[PS1_FILES]}"
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _nix_files="${ctx[NIX_FILES]}"
  if $_has_args; then
    [ ${#_sh_files[@]} -gt 0 ] && _grep_files+=("${_sh_files[@]}")
    [ ${#_ps1_files[@]} -gt 0 ] && _grep_files+=("${_ps1_files[@]}")
    [ ${#_nix_files[@]} -gt 0 ] && _grep_files+=("${_nix_files[@]}")
    local _filtered=()
    local _f
    for _f in "${_grep_files[@]}"; do
      case "$(basename "$_f")" in
      check.sh | check.ps1 | shell.nix | repo-policy-*.sh | repo-policy-*.ps1 | repository-policy*.sh | repository-policy*.ps1 | 11-repo-policy-grep.sh | 12-repo-policy-pattern.sh | 13-repo-policy-data.sh | 11-repo-policy-grep.ps1 | 12-repo-policy-pattern.ps1 | 13-repo-policy-data.ps1) continue ;;
      esac
      _filtered+=("$_f")
    done
    _grep_files=("${_filtered[@]}")
  else
    mapfile -t _grep_files < <(
      find scripts/ src/ tests/ \( -name '*.sh' -o -name '*.ps1' -o -name '*.nix' \) -print |
        filter_gitignored |
        grep -v -E '(check\.sh|check\.ps1|shell\.nix|repo-policy-.*\.(sh|ps1)|repository-policy.*\.(sh|ps1)|1[123]-repo-policy-.*\.sh)$'
    )
  fi

  if [ "${#_grep_files[@]}" -gt 0 ]; then
    if printf '%s\0' "${_grep_files[@]}" |
      xargs -0 grep -n -E '(^|[^a-z])pip install([^-]|$)' 2>/dev/null |
      grep -v 'uv pip install' |
      grep . >/dev/null 2>&1; then
      error "bare pip install detected (use uv pip install instead)"
      _violations=$((_violations + 1))
    fi

    if printf '%s\0' "${_grep_files[@]}" |
      xargs -0 grep -n -E '(^|[^a-z])npm install([^-]|$)' 2>/dev/null |
      grep . >/dev/null 2>&1; then
      error "bare npm install detected (use bun or nix instead)"
      _violations=$((_violations + 1))
    fi
  fi

  # Self-pruning: verify excluded files still justify their exclusion (A1)
  for _excluded in check.sh check.ps1 shell.nix; do
    if [ -f "$_excluded" ] && ! grep -q -E '(pip install|npm install)' "$_excluded" 2>/dev/null; then
      error "stale exclusion: '$_excluded' no longer contains pip/npm install patterns — remove from --exclude list"
      _violations=$((_violations + 1))
    fi
  done

  if [ "$_violations" -gt 0 ]; then
    return 1
  fi
  say "no package manager violations found."
  return 0
}

# Suppression audit: detect undocumented error suppressions.
# ref: allow-and-deny-lists.instructions.md#A9
run_suppression_audit() {
  local -n ctx="$1"
  shift
  cd "${ctx[REPO_ROOT]}" || return 1
  local _errors=0
  local _tmpdir
  _tmpdir=$(mktemp -d) || {
    error "failed to create temp dir"
    _errors=$((_errors + 1))
  }

  # Collect script files
  local _files=()
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _sh_files="${ctx[SH_FILES]}"
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _nix_files="${ctx[NIX_FILES]}"
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _cached_nix_files="${ctx[CACHED_NIX_FILES]}"
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _cached_shell_files="${ctx[CACHED_SHELL_FILES]}"
  if "${ctx[HAS_ARGS]}"; then
    [ ${#_sh_files[@]} -gt 0 ] && _files+=("${_sh_files[@]}")
    [ ${#_nix_files[@]} -gt 0 ] && _files+=("${_nix_files[@]}")
  else
    _files=("${_cached_nix_files[@]}" "${_cached_shell_files[@]}")
  fi

  # Drop this step's own file: its scan definitions contain the literal suppression patterns.
  local _filtered=() _f_iter
  for _f_iter in "${_files[@]}"; do
    [ "$(basename "$_f_iter")" = "$(basename "${BASH_SOURCE[0]}")" ] || _filtered+=("$_f_iter")
  done
  _files=("${_filtered[@]}")

  if [ "${#_files[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _safe="$(echo "$2" | tr "/" "_")"
        _out="$1/${_safe}.out"
        _grep_pattern="shellcheck disable=|check-suppress:"  # reason: self-reference — grep pattern literal, not a suppression
        grep -Hn -E "$_grep_pattern" "$2" \
          | grep -v -E "reason:|suppression_doc:|config-method|embedded-content|packer_validate|SuppressMessageAttribute" \
          | sed "s/^/undoc_supp:/" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: grep exits 1 on no matches; an empty .out file is the clean signal
        # Bare "|| true" suppressions: documented by "# check-suppress:suppression_doc:" on
        # the same or preceding line; test fixtures (tests/) are exempt.
        case "$2" in
          *"/tests/"* | "tests/"*) ;;
          *)
            awk "
              /^[[:space:]]*#/ { prev = \$0; next }
              /\|\| true/ {
                if (\$0 !~ /check-suppress:suppression_doc:/ && prev !~ /# check-suppress:suppression_doc:/) {
                  print FILENAME \":\" FNR \":|| true: \" \$0
                }
              }
              { prev = \$0 }
            " "$2" | sed "s/^/undoc_supp:/" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: awk exits 1 on no || true matches; an empty .out file is the clean signal
            ;;
        esac
      ' _ "$_tmpdir"

    local _f _err
    for _f in "$_tmpdir"/*.out "$_tmpdir"/.*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _errors=$((_errors + 1))
        error "$_err"
      done <"$_f"
    done

    if [ "$_errors" -gt 0 ]; then
      say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
      rm -rf -- "$_tmpdir"
      return 1
    else
      say "no undocumented error suppressions found."
    fi
  else
    say "0 script files in scope — nothing to audit."
  fi

  rm -rf -- "$_tmpdir"
  return 0
}

# run_cloud_mount_invariants — verify the two-interface invariants.
# Core cloud-mount files must not contain OS-specific FUSE/supervisor names.
run_cloud_mount_invariants() {
  local _ctx_name="$1"
  shift
  local _failed=0
  local _core_files
  _core_files="src/scripts/services/rclone-mount.sh src/scripts/services/rclone-mount.ps1"
  local _os_pattern='macfuse|fskit|WinFsp|fuse3|nucleus-cloud-repair'

  for _f in $_core_files; do
    [ -f "$_f" ] || continue
    if grep -qEi "$_os_pattern" "$_f" 2>/dev/null; then
      error "$_ctx_name: $_f contains OS-specific FUSE/backend names (invariant violation: $_os_pattern)"
      _failed=1
    fi
  done

  # One macfuse install call site (darwin backend only).
  local _install_count
  _install_count=$(grep -rl 'macfuse install\|brew install.*macfuse' src/scripts/lib/ src/scripts/services/ 2>/dev/null | wc -l || true) # check-suppress:suppression_doc: grep exits 1 when no install site matches; || echo 0 appended a second 0 under pipefail so the exactly-one assertion below never fired
  if [ "$_install_count" -ne 1 ]; then
    error "$_ctx_name: found $_install_count macfuse install call sites; must be exactly one (mount-backend-darwin.sh)"
    _failed=1
  fi

  if [ "$_failed" -ne 0 ]; then
    return 1
  fi
  say "no cloud-mount invariant violations found."
  return 0
}

# run_service_supervision_invariants — verify the uniform supervision policy.
# The rewrite locked in one loop policy, one threshold source, and one retry
# owner.  Every assertion below fails if a later change reintroduces a second
# copy of one of them; none of them inspects service identity, because loop
# protection is deliberately not configurable per service.
run_service_supervision_invariants() {
  local _ctx_name="$1"
  shift
  local _failed=0
  local _health_lib="src/scripts/lib/service-health.sh"
  local _watchdog="src/scripts/services/service-watchdog.sh"
  local _services_json="src/modules/services.json"

  # Thresholds live once, in the POSIX health library, and are compared there
  # only through their constants.  A second definition or a bare numeric
  # comparison is a second policy that can drift from the watchdog's.
  if [ -f "$_health_lib" ]; then
    local _name _defs
    for _name in _SVC_HEALTH_LOOP_RESTARTS _SVC_HEALTH_LOOP_CONSECUTIVE _SVC_HEALTH_WARN_RESTARTS; do
      _defs=$(grep -cE "^[[:space:]]*readonly ${_name}=" "$_health_lib" || true) # check-suppress:suppression_doc: grep -c exits 1 when the count is zero, which is a violation this check reports rather than ignores
      if [ "${_defs:-0}" -ne 1 ]; then
        error "$_ctx_name: $_health_lib defines $_name ${_defs:-0} times; loop thresholds must have exactly one source"
        _failed=1
      fi
    done

    local _bare
    _bare=$(grep -nE '\-(ge|gt|le|lt)[[:space:]]+"?[0-9]+' "$_health_lib" || true) # check-suppress:suppression_doc: grep exits 1 when no bare threshold remains, which is the clean result
    if [ -n "$_bare" ]; then
      error "$_ctx_name: $_health_lib compares a bare numeric threshold; use the _SVC_HEALTH_* constants: $(printf '%s' "$_bare" | tr '\n' ';')"
      _failed=1
    fi

    # Drop this step's own file: it names the constants in the loop below.
    local _self_name
    _self_name="$(basename "${BASH_SOURCE[0]}")"
    local _elsewhere
    _elsewhere=$(grep -rnE '_SVC_HEALTH_(LOOP|WARN)_[A-Z_]+' --include='*.sh' src/ scripts/ |
      grep -vE "^${_health_lib}:" |
      grep -vE "(^|/)${_self_name}:" |
      grep -vE ':[0-9]+:[[:space:]]*#' ||
      true) # check-suppress:suppression_doc: grep exits 1 when a clean tree references the constants nowhere else, which is the expected result
    if [ -n "$_elsewhere" ]; then
      error "$_ctx_name: the loop thresholds are referenced outside $_health_lib; they have one definition and one library"
      _failed=1
    fi
  fi

  # Loop protection is a property of the health record, never a per-service
  # setting.  Only the service entry's own keys are inspected, so the
  # legitimate cloud-drive.lifecycle block stays out of scope by design.
  if [ -f "$_services_json" ]; then
    local _forbidden
    if ! _forbidden=$(jq -r '
        to_entries[]
        | select(.key | startswith("$") | not)
        | select(.value | type == "object")
        | .key as $svc
        | (.value | keys)[]
        | select(test("loop|throttle|exempt"; "i"))
        | "\($svc): \(.)"
      ' "$_services_json"); then
      error "$_ctx_name: $_services_json is not valid JSON; cannot verify the loop-policy invariants"
      _failed=1
    elif [ -n "$_forbidden" ]; then
      error "$_ctx_name: $_services_json declares a per-service loop/throttle/exempt field: $(printf '%s' "$_forbidden" | tr '\n' ';')"
      error "$_ctx_name: loop protection is uniform for every service; it must not become a per-service field"
      _failed=1
    fi
  fi

  # The POSIX watchdog supervises through the supervisor backend alone; the
  # PowerShell it once carried made it unable to check anything on this host.
  if [ -f "$_watchdog" ] && grep -qiE 'ScheduledTask|schtask|ConvertTo-Json' "$_watchdog"; then
    error "$_ctx_name: $_watchdog contains PowerShell; the POSIX watchdog runs on POSIX hosts only"
    _failed=1
  fi

  # Retry and backoff belong to the shared runner alone.  A mount backend or
  # the setup step that sleeps is a second retry owner, which is how the
  # original restart storm ran without backoff.
  local _mount_path_file
  for _mount_path_file in src/scripts/lib/mount-backend-darwin.sh src/scripts/lib/mount-backend-linux.sh src/scripts/services/cloud-drives-setup.sh; do
    [ -f "$_mount_path_file" ] || continue
    if grep -qE '(^|[^[:alnum:]_])sleep([^[:alnum:]_]|$)' "$_mount_path_file"; then
      error "$_ctx_name: $_mount_path_file sleeps; retry/backoff is owned by the shared runner (src/scripts/services/rclone-mount.sh)"
      _failed=1
    fi
  done

  # Only the watchdog may act on the loop predicate.  A service script that
  # calls it is enforcing a private throttle instead of reporting health.
  local _consumers
  _consumers=$(grep -rnE 'svc_health_is_looping[[:space:]]+[^[:space:]]' --include='*.sh' src/scripts/ scripts/ |
    grep -vE ':[0-9]+:[[:space:]]*#' |
    cut -d: -f1 |
    sort -u ||
    true) # check-suppress:suppression_doc: grep exits 1 when nothing consumes the predicate, which is a violation this check reports rather than ignores
  local _consumer
  for _consumer in $_consumers; do
    case "$_consumer" in
    src/scripts/lib/service-health.sh | src/scripts/services/service-watchdog.sh) ;;
    *)
      error "$_ctx_name: $_consumer calls svc_health_is_looping; the watchdog is the only loop-policy consumer"
      _failed=1
      ;;
    esac
  done

  if [ "$_failed" -ne 0 ]; then
    return 1
  fi
  say "no service supervision invariant violations found."
  return 0
}
