# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "nix-test-eval" 24 "Nix test evaluation guard" run_24_nix_test_eval

run_24_nix_test_eval() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s24_errors=0
  # Exclude this check's own file: its source contains the literal detection
  # patterns (1-argument deepSeq and length-only no-op forms) as regexes.
  # ref: allow-and-deny-lists.instructions.md#C7 -- self-refs are dynamic
  local _s24_self_sh
  _s24_self_sh="$(basename "${BASH_SOURCE[0]}")"

  # Scan scope: Nix test files under tests/, excluding the shared test helper
  # lib.nix (see allow-and-deny-lists.instructions.md#A6). Non-.nix harness
  # files and fixtures outside tests/ are out of scope.
  local _scan_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
        tests/*.nix)
          case "$(basename "$_f")" in
            lib.nix|"$_s24_self_sh") ;;
            *) _scan_files+=("$_f") ;;
          esac
          ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      _scan_files+=("$_f")
    done < <(find tests -type f -name '*.nix' -not -name 'lib.nix' -not -name "$_s24_self_sh" -print0)
    mapfile -t _scan_files < <(printf '%s\n' "${_scan_files[@]}" | filter_gitignored)
  fi

  # Pattern 1: 1-argument builtins.deepSeq inside builtins.seq — a partial
  # application.  `builtins.seq (builtins.deepSeq allTests) { ... }` forces only
  # the lambda (WHNF), never the tests: every assertion is silently skipped.
  # The 2-argument form `builtins.seq (builtins.deepSeq allTests null)` is
  # correct (deepSeq's second argument is the forced value) and does not match.
  if [ "${#_scan_files[@]}" -gt 0 ]; then
    local _s24_hit
    while IFS= read -r _s24_hit; do
      _s24_errors=$((_s24_errors + 1))
      error "$_s24_hit"
    done < <(grep -nH -E '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq\s+[A-Za-z_][A-Za-z0-9_]*\s*\)' "${_scan_files[@]}")
  fi

  # Pattern 2: tests counted via builtins.length but never forced.  A file that
  # ends with `success = true; testCount = builtins.length allTests;` (or
  # all_tests) without any forcing construct — builtins.seq/deepSeq,
  # builtins.all, builtins.filter, inherit, or a top-level assert — evaluates
  # nothing and passes silently.  See .agents/instructions/testing.instructions.md.
  local _s24_file
  for _s24_file in "${_scan_files[@]}"; do
    if grep -qE 'builtins\.length\s+(allTests|all_tests)' "$_s24_file" \
      && grep -q 'success = true' "$_s24_file" \
      && ! grep -qE 'builtins\.(seq|deepSeq|all|filter)|^[[:space:]]*assert[[:space:]]' "$_s24_file"; then
      _s24_errors=$((_s24_errors + 1))
      error "$_s24_file: Nix tests are only counted via builtins.length but never forced — assertions are silently skipped (see .agents/instructions/testing.instructions.md)"
    fi
  done

  if [ "$_s24_errors" -gt 0 ]; then
    say "  Force evaluation of every test file — see .agents/instructions/testing.instructions.md."
    return 1
  fi

  say "all Nix test files force evaluation of their assertions."
  return 0
}
