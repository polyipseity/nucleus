#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "repo-policy-grep" "Repository policy (grep-heavy)" run_repo_policy_grep posix any none

# Sub-checks in output order, as "<label>|<function>|<style>".
_POLICY_GREP_CHECKS=(
  "activation tool resolution|run_activation_tool_resolution|ctx"
  "suppression audit|run_suppression_audit|ctx"
  "cloud-mount invariants|run_cloud_mount_invariants|ctx"
  "service supervision invariants|run_service_supervision_invariants|ctx"
)

run_repo_policy_grep() {
  local _ctx_name="$1"
  shift
  run_policy_checks "$_ctx_name" "repository policy (grep-heavy)" _POLICY_GREP_CHECKS "$@"
}

run_activation_tool_resolution() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

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

  local _activation_dirs=(
    src/scripts/ai src/scripts/packages src/scripts/shell src/scripts/agents
    src/scripts/secrets src/scripts/services src/scripts/vms
    src/scripts/configs src/scripts/editors src/scripts/integrations
    src/scripts/completions
  )

  # ref: comment-annotations.instructions.md#C1 -- self-derived basename for self-exclusion
  # The android guest scripts run in a guest with no Nix store, so their `ip` can
  # take neither a store-path arg nor a PATH prepend.
  # ref: allow-and-deny-lists.instructions.md#A10 -- guest scripts have no Nix store to resolve against
  # path_basename rather than basename: separator-agnostic and fork-free, matching the sibling sub-checks.
  path_basename "${BASH_SOURCE[0]}"
  local _self_sh="$REPLY"
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
          path_basename "$_f"
          case "$REPLY" in
          "$_self_sh" | android-fake-wifi-guest-*.sh) continue 2 ;;
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
        # shellcheck disable=SC2046 # reason: echo expands the find array safely, no globbing risk
        find "${_find_dirs[@]}" -name '*.sh' -print |
          filter_gitignored |
          LC_ALL=C sort |
          grep -v -E '(android-fake-wifi-guest-.*\.sh|'"$_self_sh"')$'
      )
    fi
  fi

  if [ "${#_candidate_files[@]}" -eq 0 ]; then
    say "0 activation scripts in scope — nothing to resolve."
    return 0
  fi

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
    {
      grep -h -E '^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\(\)' "${_candidate_files[@]}" 2>/dev/null |
        sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*().*//' |
        grep -E '^[a-zA-Z_][a-zA-Z_0-9]*$' | sort -u
      grep -h -E '^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*' "${_candidate_files[@]}" 2>/dev/null |
        sed 's/^[[:space:]]*function[[:space:]]*//' | sed 's/[[:space:]].*//' |
        grep -E '^[a-zA-Z_][a-zA-Z_0-9]*$' | sort -u
    }
  } >"$_lib_funcs_file"

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

# One awk run covers every file, so per-file state resets here; without it one
# unbalanced construct blinds every file scanned after it.
FNR == 1 {
  in_heredoc = 0
  heredoc_delim = ""
  case_depth = 0
  in_embedded = 0
  embedded_close = ""
  pending = ""
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

# An awk or jq body passed to a resolved binary is program text, not shell. This
# rule has to sit above the case and bare-quote rules: a program line that looks
# like a case opener would raise case_depth, and the bare-quote rule would leave
# the rest of the body to be read as commands.
in_embedded {
  if (index($0, embedded_close) > 0) in_embedded = 0
  next
}
{
  # Walk quotes that start a word: a quote inside a token belongs to it, so the
  # first quote that does not close on its own line opens a multi-line argument.
  rest = $0
  opener = ""
  while (match(rest, /(^|[[:space:]])[`'\"]/)) {
    _q = substr(rest, RSTART + RLENGTH - 1, 1)
    _after = substr(rest, RSTART + RLENGTH)
    if (index(_after, _q) > 0) {
      rest = substr(_after, index(_after, _q) + 1)
      continue
    }
    opener = _q
    break
  }
  if (opener != "" && $0 ~ /(_bin|awk|jq)/) {
    in_embedded = 1
    embedded_close = opener
    next
  }
}

# A one-line `case ... esac` carries its own terminator, so raise depth only when
# the line does not already close it.
/^[[:space:]]*case[[:space:]]/ {
  if ($0 !~ /(^|[^-[:alnum:]_])esac([[:space:]]|$)/) case_depth++
  next
}
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
  # A trailing backslash continues the command; without this the continuation is
  # read as its own command and a leading 2>/dev/null is reported as a bare binary.
  if (pending != "") {
    line = pending " " line
    pending = ""
  }
  if (line ~ /\\$/) {
    sub(/\\$/, "", line)
    pending = line
    next
  }
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
    # The program resets in_heredoc/case_depth/in_embedded on FNR == 1 because
    # one awk run sees every file; without the reset an unbalanced construct
    # blinds every later file and a green result here proves nothing.
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

# Suppression audit: undocumented error suppressions.
# ref: allow-and-deny-lists.instructions.md#A9
run_suppression_audit() {
  local -n ctx="$1"
  shift
  cd "${ctx[REPO_ROOT]}" || return 1
  local _errors=0
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

  # Drop this step's own file: its scan definitions contain the literal
  # suppression patterns. path_basename rather than basename keeps the per-file
  # cost at zero forks, and it also matches a Windows-shaped path.
  local _filtered=() _f_iter _self_name
  path_basename "${BASH_SOURCE[0]}"
  _self_name="$REPLY"
  for _f_iter in "${_files[@]}"; do
    path_basename "$_f_iter"
    [ "$REPLY" = "$_self_name" ] || _filtered+=("$_f_iter")
  done
  _files=("${_filtered[@]}")

  # Same scan over PowerShell. Scoped mode takes the .ps1 positional list,
  # whole-repo mode enumerates every .ps1 outside vendor/ behind the gitignore
  # filter. The repo-policy step files are dropped in both modes because they
  # carry this scan's own pattern text.
  # ref: allow-and-deny-lists.instructions.md#A12 -- the step files hold the scan's own patterns
  local _ps1_candidates=()
  # shellcheck disable=SC2178 # reason: nameref to context array
  local -n _ps1_ctx_files="${ctx[PS1_FILES]}"
  if "${ctx[HAS_ARGS]}"; then
    _ps1_candidates=("${_ps1_ctx_files[@]}")
  else
    mapfile -t _ps1_candidates < <(
      # ref: allow-and-deny-lists.instructions.md#B7 -- vendor/ is a structural invariant; the gitignore filter is applied on top
      find . -name '*.ps1' -not -path '*/vendor/*' -print |
        filter_gitignored |
        LC_ALL=C sort
    )
  fi
  local _ps1_files=() _ps1_iter
  for _ps1_iter in "${_ps1_candidates[@]}"; do
    path_basename "$_ps1_iter"
    case "$REPLY" in
    11-repo-policy-grep.ps1 | 12-repo-policy-pattern.ps1 | 13-repo-policy-data.ps1) continue ;;
    esac
    _ps1_files+=("$_ps1_iter")
  done

  # One awk process over every file, applying the pattern table and the
  # annotation audit line by line instead of spawning a child chain per file.
  # Message text is unchanged, but the whole violation set is sorted and
  # deduplicated as one list, so the shell and PowerShell halves can interleave
  # differently and exact duplicate lines collapse.
  local _scan_files=("${_files[@]}" "${_ps1_files[@]}")
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    local _awk_program
    # check-suppress:embedded-content: exception 1 (data-driven/generated) -- awk program for the suppression audit
    read -r -d '' _awk_program <<'AWKEOF'
function add_pattern(p, l, c, e, f) {
  _count++
  pat[_count] = p
  label[_count] = l
  id[_count] = c
  exempt[_count] = e
  ps1[_count] = f
}

# Repo-relative, so a checkout that merely lives under a directory named tests
# is still audited.
function is_tests(path,   rel, root_lc) {
  root_lc = tolower(ROOT)
  rel = path
  if (root_lc != "" && index(tolower(rel), root_lc) == 1) {
    rel = substr(rel, length(ROOT) + 2)
  } else {
    sub(/^\.[\/]/, "", rel)
  }
  return (rel ~ "(^|/)tests/")
}

BEGIN {
  # One entry per pattern: ERE, report label, documenting check id (empty when
  # no annotation documents it), whether the tests/ exemption applies, and
  # whether it belongs to the PowerShell half. The PowerShell entries mirror
  # Get-UndocSuppViolation in 11-repo-policy-grep.ps1; a .ps1 file is the only
  # thing that half reads, and everything else is shell or Nix.
  add_pattern("[|][|] true", "|| true", "suppression_doc", 1, 0)
  add_pattern("2>[$]null", "2>$null", "suppression_doc", 1, 1)
  add_pattern("-erroraction silentlycontinue", "-ErrorAction SilentlyContinue", "suppression_doc", 1, 1)
  add_pattern("catch[[:space:]]*\\{[[:space:]]*\\}", "empty catch {}", "suppression_doc", 0, 1)
  add_pattern("[|] out-null", "| Out-Null", "", 0, 1)
  add_pattern("[$]null[[:space:]]*=[[:space:]]*[^[:space:]]", "$null =", "suppression_doc", 1, 1)
  add_pattern("\\[void\\]", "[void]", "suppression_doc", 1, 1)
  add_pattern("suppressmessageattribute\\(", "SuppressMessageAttribute", "SuppressMessageAttribute", 0, 1)
}

FNR == 1 {
  prev = ""
  _under_tests = is_tests(FILENAME)
  _is_ps1 = (FILENAME ~ "[.]ps1$")
}

{
  line = tolower($0)
  if (line !~ "^[ \t]*#") {
    for (_i = 1; _i <= _count; _i++) {
      if (ps1[_i] != _is_ps1) continue
      if (exempt[_i] && _under_tests) continue
      if (line !~ pat[_i]) continue
      if (id[_i] != "") {
        # The registry spells the id in mixed case and the matched line is lowercased.
        _id = tolower(id[_i])
        if (line ~ ("# check-suppress:" _id "[ \t:]")) continue
        if (FNR > 1 && prev ~ ("# check-suppress:" _id)) continue
      }
      # The shell half repeats the line, because the annotation on it is what a
      # reader has to see to fix it; the PowerShell half names the pattern.
      if (ps1[_i]) {
        printf "%s:%d (%s)\n", FILENAME, FNR, label[_i]
      } else {
        printf "undoc_supp:%s:%d:%s: %s\n", FILENAME, FNR, label[_i], $0
      }
    }
  }
  # A `shellcheck disable=` or `check-suppress:` line is documented by a
  # registered check id, or by `reason:` for a shellcheck directive. The
  # PowerShell half reads PowerShell annotations only, so this rule skips a
  # .ps1 file. Comment lines are scanned on purpose: a comment carrying an
  # unregistered id is exactly what this rule is for.
  if (!_is_ps1 && $0 ~ /shellcheck disable=|check-suppress:/ &&
      $0 !~ /reason:|suppression_doc:|config-method|embedded-content|packer_validate|SuppressMessageAttribute/) {
    printf "undoc_supp:%s:%d:%s\n", FILENAME, FNR, $0
  }
  prev = line
}
AWKEOF

    local _scan_output _violations
    # Nothing in this call chain enables errexit, and a pipeline carries the
    # status of its last command, so the scan is checked before the sort.
    if ! _scan_output=$(
      printf '%s\0' "${_scan_files[@]}" |
        xargs -0 awk -v ROOT="${ctx[REPO_ROOT]}" "$_awk_program"
    ); then
      error "suppression audit scan failed"
      return 1
    fi
    _violations=$(printf '%s\n' "$_scan_output" | LC_ALL=C sort -u)
    while IFS= read -r _err; do
      [ -z "$_err" ] && continue
      _errors=$((_errors + 1))
      error "$_err"
    done <<<"$_violations"

    if [ "$_errors" -gt 0 ]; then
      say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
      return 1
    fi
    say "no undocumented error suppressions found."
  else
    say "0 script files in scope — nothing to audit."
  fi

  return 0
}

# Core cloud-mount files must not name OS-specific FUSE or supervisor backends.
run_cloud_mount_invariants() {
  local _ctx_name="$1"
  shift
  local _failed=0
  local _core_files
  _core_files="src/scripts/services/rclone-mount.sh src/scripts/services/rclone-mount.ps1"
  local _os_pattern='macfuse|fskit|WinFsp|fuse3|fuse-t'

  for _f in $_core_files; do
    [ -f "$_f" ] || continue
    if grep -qEi "$_os_pattern" "$_f" 2>/dev/null; then
      error "$_ctx_name: $_f contains OS-specific FUSE/backend names (invariant violation: $_os_pattern)"
      _failed=1
    fi
  done

  # macOS cloud mounts run through fuse-t, so the dependency must be declared
  # in the machine package surface; a missing declaration leaves every macOS
  # mount failing at the FUSE library step. The mount path itself installs
  # nothing: the cask is Nix-managed (src/hosts/MacBook/homebrew.nix).
  local _decl_count _install_count
  # check-suppress:suppression_doc: grep exits 1 when no declaration matches; the count check below reports that as a violation
  _decl_count=$(grep -ci 'fuse-t' src/hosts/MacBook/homebrew.nix 2>/dev/null || true)
  if [ "${_decl_count:-0}" -lt 1 ]; then
    error "$_ctx_name: no fuse-t declaration in src/hosts/MacBook/homebrew.nix; macOS cloud mounts need the cask"
    _failed=1
  fi

  _install_count=$(grep -rl 'macfuse install\b\|brew install.*macfuse\|fuse-t install\b\|brew install.*fuse-t' src/scripts/lib/ src/scripts/services/ 2>/dev/null | wc -l || true) # check-suppress:suppression_doc: grep exits 1 when no install site matches; the count must read zero either way
  if [ "$_install_count" -ne 0 ]; then
    error "$_ctx_name: found $_install_count FUSE-library install call sites; the mount path must install none (the cask is Nix-managed)"
    _failed=1
  fi

  if [ "$_failed" -ne 0 ]; then
    return 1
  fi
  say "no cloud-mount invariant violations found."
  return 0
}

# One loop policy, one threshold source, one retry owner. Every assertion below
# fails if a later change adds a second copy; none inspects service identity,
# because loop protection is deliberately not configurable per service.
run_service_supervision_invariants() {
  local _ctx_name="$1"
  shift
  local _failed=0
  local _health_lib="src/scripts/lib/service-health.sh"
  local _watchdog="src/scripts/services/service-watchdog.sh"
  local _services_json="src/modules/services.json"

  # Thresholds live once in the POSIX health library and are compared only
  # through their constants; a second definition or a bare number is a policy
  # that can drift from the watchdog's.
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

  # Loop protection is a property of the health record, so only the service
  # entry's own keys are inspected and the cloud-drive.lifecycle block stays out
  # of scope.
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

  # The watchdog runs on POSIX hosts only, so it must contain no PowerShell.
  if [ -f "$_watchdog" ] && grep -qiE 'ScheduledTask|schtask|ConvertTo-Json' "$_watchdog"; then
    error "$_ctx_name: $_watchdog contains PowerShell; the POSIX watchdog runs on POSIX hosts only"
    _failed=1
  fi

  # Retry and backoff belong to the platform manager (launchd KeepAlive,
  # systemd Restart=always, the Windows task loop); a setup step that sleeps
  # is a second retry owner.
  # WHY one path and no loop: the sleep ban covered the mount runners until
  #   they became platform-managed, leaving the setup script as the only
  #   cloud-mount script where a sleep would reintroduce a second retry owner.
  local _mount_path_file=src/scripts/services/cloud-drives-setup.sh
  if [ -f "$_mount_path_file" ] && grep -qE '(^|[^[:alnum:]_])sleep([^[:alnum:]_]|$)' "$_mount_path_file"; then
    error "$_ctx_name: $_mount_path_file sleeps; retry/backoff is owned by the platform manager (launchd KeepAlive, systemd Restart=always, the Windows task loop)"
    _failed=1
  fi

  # Only the watchdog may act on the loop predicate; a service script calling it
  # enforces a private throttle instead of reporting health.
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
