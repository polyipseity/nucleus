# shellcheck shell=bash
# Nix test evaluation guard — makes sure tests/ .nix files force assertions before eval.
# Wired from test step 01 (01-nix-tests.sh) before nix-instantiate --eval --strict.
# shellcheck source=deny-list.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deny-list.sh"

# Source lib.sh from this library's own directory (callers set SCRIPT_DIR to
# their own location, so resolve relative to this file).
_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
. "$_LIB_DIR/lib.sh"
unset _LIB_DIR

run_nix_test_eval() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _nte_errors=0
  # Exclude this library file when invoked from a path under tests/: its source
  # contains the literal detection patterns as regexes.
  local _nte_self_sh
  _nte_self_sh="$(basename "${BASH_SOURCE[0]}")"

  local _scan_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
      tests/*.nix)
        case "$(basename "$_f")" in
        lib.nix | "$_nte_self_sh") ;;
        *) _scan_files+=("$_f") ;;
        esac
        ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _scan_files+=("$_f")
    done < <(find tests -type f -name '*.nix' -not -name 'lib.nix' -not -name "$_nte_self_sh" -print0)
    mapfile -t _scan_files < <(printf '%s\n' "${_scan_files[@]}" | filter_gitignored)
  fi

  if [ "${#_scan_files[@]}" -gt 0 ]; then
    local _nte_hit
    while IFS= read -r _nte_hit; do
      _nte_errors=$((_nte_errors + 1))
      warn -l test "$_nte_hit"
    done < <(grep -nH -E '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq\s+[A-Za-z_][A-Za-z0-9_]*\s*\)' "${_scan_files[@]}")
  fi

  local _nte_file
  for _nte_file in "${_scan_files[@]}"; do
    if grep -qE 'builtins\.length\s+(allTests|all_tests)' "$_nte_file" &&
      grep -q 'success = true' "$_nte_file" &&
      ! grep -qE 'builtins\.(seq|deepSeq|all|filter)|^[[:space:]]*assert[[:space:]]' "$_nte_file"; then
      _nte_errors=$((_nte_errors + 1))
      warn -l test "$_nte_file: Nix tests are only counted via builtins.length but never forced — assertions are silently skipped (see .agents/instructions/testing.instructions.md)"
    fi
  done

  if [ "$_nte_errors" -gt 0 ]; then
    warn -l test "  Force evaluation of every test file — see .agents/instructions/testing.instructions.md."
    return 1
  fi

  return 0
}
