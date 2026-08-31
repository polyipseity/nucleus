# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "activation-tool-resolution" "Activation script tool resolution" run_activation_tool_resolution

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
      skip_step "$(step_number)" "Activation script tool resolution" "no shell files to check"
      return 2
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
          "$_self_sh" | check.sh) continue 2 ;;
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
          grep -v -E '(check\.sh|'"$_self_sh"')$'
      )
    fi
  fi

  if [ "${#_candidate_files[@]}" -eq 0 ]; then
    skip_step "$(step_number)" "Activation script tool resolution" "no activation scripts to check"
    return 2
  fi

  # --- Build dynamic allowlist of repo-defined functions ---
  # Collect all function names from src/scripts/lib/*.sh so the awk program
  # does not flag calls to sourced lib functions.
  local _lib_funcs_file
  _lib_funcs_file=$(mktemp)
  # shellcheck disable=SC2155 # reason: mktemp exit status checked below
  [ -f "$_lib_funcs_file" ] || {
    error "failed to create temp file for lib functions"
    return 1
  }
  {
    # Match both name() { and function name { patterns.
    grep -rh -E '^[a-zA-Z_][a-zA-Z_0-9]*\(\)' src/scripts/lib/ 2>/dev/null |
      sed 's/[[:space:]]*().*//' | sort -u
    grep -rh -E '^function[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*' src/scripts/lib/ 2>/dev/null |
      sed 's/^function[[:space:]]*//' | sed 's/[[:space:]].*//' | sort -u
  } >"$_lib_funcs_file"

  # --- Awk scan ---
  # Single-pass per file tracking PATH prepends, heredocs, case blocks,
  # and detecting bare external commands.
  #
  # Key design decisions:
  # 1. Strip path prefix BEFORE allowlist check so /bin/mkdir etc. are recognized.
  # 2. Track heredoc bodies (handle <<DELIM >&2, >file <<DELIM, etc.).
  # 3. Track case/esac blocks to skip case pattern lines.
  # 4. Validate command names: only flag tokens matching [a-z_][a-z0-9_-]*
  #    to eliminate flags, globs, colons, uppercase, etc.
  # 5. Load lib function names from a temp file to avoid flagging sourced calls.
  # 6. Fix the 'command' prefix handling bug (use rest offset, not line offset).
  local _awk_program
  read -r -d '' _awk_program <<'AWKEOF'
BEGIN {
  in_heredoc = 0
  heredoc_delim = ""
  case_depth = 0
  violations = 0

  # --- Allow-list: commands always available on PATH ---
  # Shell builtins
  split("set export local readonly declare if then else elif fi for while do done case esac function return exit trap shift source . eval exec cd pwd echo printf read test [ [[ true false break continue wait kill shopt type hash builtin command enable help let unset popd pushd dirs complete compgen compopt mapfile readarray caller times suspend", a)
  for (i in a) allow[a[i]] = 1;  delete a
  # Coreutils / POSIX
  split("cat chmod chown cp date dd df du env expand expr factor fmt fold head id install join link ln logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc od paste pathchk pinky pr printenv ptx readlink realpath rm rmdir sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort stat stty sum sync tac tail tee touch tr truncate tsort tty uname unexpand uniq unlink users vdir wc who whoami yes seq stdbuf", a)
  for (i in a) allow[a[i]] = 1;  delete a
  # Common shell utilities / privilege escalation
  split("grep sed awk find xargs cut diff file which man basename dirname timeout sudo curl tar gzip gunzip chmod kill rm ln cp mv mkdir touch chmod killall lsof fuser env time mktemp", a)
  for (i in a) allow[a[i]] = 1;  delete a
  # Additional utilities common in activation scripts (NixOS profile tools,
  # system management, etc. — always on PATH in NixOS/darwin environments)
  split("nix nix-env nix-build nix-channel nix-shell nix-store nix-collect-garbage nix-instantiate nix-prefetch-url nix-store nix-hash nixos-rebuild darwin-rebuild systemctl launchctl sw_vers xcode-select brew nix-shell nix-build git ssh scp rsync tar unzip zip make cmake cargo rustup rustc bun node npm npx python3 pip3 jq yq xmlstarlet xsltproc gawk getopt", a)
  for (i in a) allow[a[i]] = 1;  delete a
  # Repo-specific shell functions loaded dynamically from lib files.
  # The lib_funcs_file is read below.
}

# --- Load lib function names from temp file ---
LIB_FUNCS_FILE != "" {
  while ((getline _lf < LIB_FUNCS_FILE) > 0) {
    if (_lf != "") allow[_lf] = 1
  }
  close(LIB_FUNCS_FILE)
}

# --- Track heredoc state ---
# Detect <<DELIM (possibly followed by whitespace/redirects) but NOT <<<
# or inside comments.
/[^<]<<-?[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*([[:space:]].*|$)/ || /^<<-?[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*([[:space:]].*|$)/ {
  if (!in_heredoc) {
    line = $0
    # Extract delimiter from the <<DELIM pattern.
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

# Skip comments and empty lines.
/^[[:space:]]*(#|$)/ { next }

# --- Track case/esac depth ---
/^[[:space:]]*case[[:space:]]/ { case_depth++; next }
/^[[:space:]]*esac\b/ { if (case_depth > 0) case_depth--; next }
# While inside a case block, skip pattern lines (they contain glob chars,
# colons, or are just labels — not commands).
case_depth > 0 { next }

# Track PATH= prepends (NOT "export PATH").
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

# Collect function definitions: name() { or function name {.
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

# Skip pure variable assignments, including compound += and -=.
/^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*[\+\-]?=/ { next }

# Skip lines starting with a quoted string (store-path invocation).
/^[[:space:]]*["']/ { next }

# --- Extract command token ---
{
  line = $0
  gsub(/^[[:space:]]+/, "", line)

  # Skip lines that are shell syntax tokens.
  if (line ~ /^[{});]/ || line ~ /^;;/ || line ~ /^esac\b/ || line ~ /^fi\b/ ||
      line ~ /^done\b/ || line ~ /^then\b/ || line ~ /^else\b/ || line ~ /^do\b/) next

  match(line, /^[^[:space:];|&()]+/)
  if (RSTART == 0 || RLENGTH == 0) next
  cmd = substr(line, RSTART, RLENGTH)
  _cmd_end = RSTART + RLENGTH  # save position after first token

  # Skip past control-flow keywords (if, while, until, elif), optional !,
  # variable assignments, and quoted commands before the actual command.
  if (cmd == "if" || cmd == "while" || cmd == "until" || cmd == "elif") {
    rest = substr(line, _cmd_end)
    gsub(/^[[:space:]]+/, "", rest)
    if (substr(rest, 1, 1) == "!") {
      rest = substr(rest, 2)
      gsub(/^[[:space:]]+/, "", rest)
    }
    # Skip variable assignments before the command.
    while (match(rest, /^[a-zA-Z_][a-zA-Z_0-9]*[\+\-]?=/)) {
      rest = substr(rest, RSTART + RLENGTH)
      gsub(/^[[:space:]]+/, "", rest)
    }
    # If the next token is a quoted string (store-path invocation), skip.
    if (substr(rest, 1, 1) == "\"" || substr(rest, 1, 1) == "'") next
    match(rest, /^[^[:space:];|&()]+/)
    if (RSTART == 0 || RLENGTH == 0) next
    cmd = substr(rest, RSTART, RLENGTH)
    _cmd_end = RSTART + RLENGTH
  }

  # Skip past command/enable + optional flags.
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

  # Skip absolute-path commands (e.g., /bin/mkdir, /usr/bin/touch).
  if (cmd ~ /^\//) next

  # Strip path prefix for the allowlist check and error messages.
  sub(/.*\//, "", cmd)

  # Skip empty command after stripping.
  if (cmd == "") next

  # Skip shell syntax tokens that may appear after stripping.
  if (cmd == "{" || cmd == "}" || cmd == ")" || cmd == ";;" || cmd == "esac" ||
      cmd == "fi" || cmd == "done" || cmd == "then" || cmd == "else" || cmd == "do") next

  # --- Command name validation ---
  # Only flag tokens that look like valid external command names:
  # lowercase letter or underscore start, then lowercase letters, digits,
  # underscores, or hyphens.  This eliminates flags (--foo, -x), globs
  # (nightly*, gpg_*), case labels (group:*, user:*), option arguments
  # (--argjson, --sops-file), redirects (>"file"), dollar-expanded tokens,
  # uppercase tokens (EOF, Write-Host, Linux, Darwin, etc.), and numeric
  # tokens (1., 2., ...).
  if (cmd !~ /^[a-z_][a-z0-9_-]*$/) next

  # Skip very short tokens that are likely abbreviations or parts of
  # larger expressions (single-char or two-char).
  if (length(cmd) < 3) next

  # Check allow-lists (lib functions loaded from file + static builtins).
  if (cmd in allow) next
  if (cmd in path_provided) next
  if (cmd in local_funcs) next

  # Violation: bare external command not resolved.
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

  # Clean up temp file.
  rm -f "$_lib_funcs_file"

  # Report violations from awk output
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
