#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 25 vm-manifest-regression must flag manifest-contract regressions
# (byte-count refs, binary literals, hard-coded ports, KB/KiB, mib/gib
# identifiers) and accept the sanctioned adapter sites.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/25-vm-manifest-regression.sh"

# Run the step's check function in a subshell; returns its exit code.
run_step25() {
  # shellcheck source=../../../src/scripts/checks/check-steps/25-vm-manifest-regression.sh
  ( . "$TEST_FILE"; run_25_vm_manifest_regression "$@" >/dev/null 2>&1 )
}

test_step25_has_register_step() {
  if grep -q 'register_step "vm-manifest-regression" 25' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should register as vm-manifest-regression"
  return 1
}

test_step25_has_rambytes_pattern() {
  # G1: no byte-count manifest property refs (ramBytes/diskBytes)
  if grep -qF '\.ramBytes|\.diskBytes|"ramBytes"|"diskBytes"' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect ramBytes/diskBytes property refs"
  return 1
}

test_step25_has_gib_literal_pattern() {
  # G2: no binary GiB literals (524288/536870912/1073741824)
  if grep -qF '524288|536870912|1073741824' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect binary GiB literals"
  return 1
}

test_step25_has_mib_literal_pattern() {
  # G3: no 1048576 (1 MiB) outside the size parsers
  if grep -qF '1048576' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect the MiB literal 1048576"
  return 1
}

test_step25_has_port_pattern() {
  # G5: no hard-coded host-side ports
  if grep -qF 'hostfwd=tcp::' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect hard-coded hostfwd ports"
  return 1
}

test_step25_has_kb_pattern() {
  # G6: no invalid suffix forms KB/KiB
  if grep -qF 'KB([^A-Za-z]' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect the invalid KB/KiB suffix forms"
  return 1
}

test_step25_has_identifier_pattern() {
  # G7: no unit-in-identifier names (mib/gib)
  if grep -qF 'mib|gib' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should detect unit-in-identifier names (mib/gib)"
  return 1
}

test_step25_has_parser_exclusions() {
  # The three size parser files define the suffix grammar and must be excluded.
  if grep -qF 'src/scripts/lib/size.sh' "$TEST_FILE" \
    && grep -qF 'SizeStrings.ps1' "$TEST_FILE" \
    && grep -qF 'src/modules/lib/size.nix' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should exclude the three size parser files"
  return 1
}

test_step25_has_self_exclusion() {
  # Both step files contain every guard literal; both must be excluded.
  if grep -q 'basename.*BASH_SOURCE' "$TEST_FILE" \
    && grep -qF '25-vm-manifest-regression.ps1' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should exclude its own source files"
  return 1
}

test_step25_scopes_production_dirs() {
  # Matches: case "$_f" in src/*|scripts/*)
  if grep -qF 'src/*|scripts/*' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should only scan src/ and scripts/ in scoped mode"
  return 1
}

test_step25_scopes_code_extensions() {
  # Matches: *.ps1|*.sh|*.zsh|*.nix|*.yml
  if grep -qF '*.ps1|*.sh|*.zsh|*.nix|*.yml' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should scan only code extensions (.ps1 .sh .zsh .nix .yml)"
  return 1
}

test_step25_uses_gitignore_filter() {
  if grep -q 'filter_gitignored' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 25 should apply the gitignore filter to its file list"
  return 1
}

test_step25_behavioral_rejects_rambytes() {
  # Behavioral: a fixture with a .ramBytes ref must fail the check (G1).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'vm.ramBytes = 8000000000\n' > "$_tmpdir/src/fixture.ps1"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/fixture.ps1" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject .ramBytes in scoped mode"
  return 1
}

test_step25_behavioral_rejects_gib_literal() {
  # Behavioral: a fixture with 1073741824 outside the parsers must fail (G2).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src/scripts"
  printf 'x = 1073741824\n' > "$_tmpdir/src/scripts/fixture.sh"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/scripts/fixture.sh" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject 1073741824 outside the size parsers"
  return 1
}

test_step25_behavioral_rejects_mib_literal() {
  # Behavioral: a fixture with 1048576 outside the parsers must fail (G3).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'x = 1048576\n' > "$_tmpdir/src/fixture.nix"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/fixture.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject 1048576 outside the size parsers"
  return 1
}

test_step25_behavioral_rejects_port() {
  # Behavioral: a fixture with a hard-coded hostfwd port must fail (G5).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'hostfwd=tcp::22020-:22\n' > "$_tmpdir/src/fixture.sh"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/fixture.sh" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject hostfwd=tcp::22020 in scoped mode"
  return 1
}

test_step25_behavioral_rejects_kb() {
  # Behavioral: a fixture with an invalid KB suffix must fail (G6).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'size = 8KB\n' > "$_tmpdir/src/fixture.nix"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/fixture.nix" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject the invalid KB suffix"
  return 1
}

test_step25_behavioral_rejects_identifier() {
  # Behavioral: a fixture with a new unit-in-identifier name must fail (G7).
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'foo_gib = 1\n' > "$_tmpdir/src/fixture.sh"
  _exit_code=0
  run_step25 true "$_tmpdir" "src/fixture.sh" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject a new *_gib identifier"
  return 1
}

test_step25_behavioral_accepts_sanctioned() {
  # Behavioral: sanctioned sites (tart adapter, df -Pk KiB message) must NOT be flagged.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src/scripts"
  cat > "$_tmpdir/src/scripts/fixture.sh" <<'EOF'
_mem_gib="$(( (_ram_bytes + 1073741823) / 1073741824 ))"
KiB available, requires
EOF
  _exit_code=0
  run_step25 true "$_tmpdir" "src/scripts/fixture.sh" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -eq 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should accept sanctioned adapter/parser-adjacent content"
  return 1
}

test_step25_behavioral_rejects_full_mode() {
  # Behavioral: full mode must also flag a violation in src/.
  local _tmpdir _exit_code
  _tmpdir=$(mktemp -d) || return 1
  mkdir -p "$_tmpdir/src"
  printf 'value = 8KiB\n' > "$_tmpdir/src/fixture.nix"
  _exit_code=0
  run_step25 false "$_tmpdir" || _exit_code=$?
  rm -rf "$_tmpdir"
  if [ "$_exit_code" -ne 0 ]; then
    return 0
  fi
  echo "FAIL: step 25 should reject 8KiB in full mode"
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_register_step" ]; then
  test_step25_has_register_step || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_rambytes_pattern" ]; then
  test_step25_has_rambytes_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_gib_literal_pattern" ]; then
  test_step25_has_gib_literal_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_mib_literal_pattern" ]; then
  test_step25_has_mib_literal_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_port_pattern" ]; then
  test_step25_has_port_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_kb_pattern" ]; then
  test_step25_has_kb_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_identifier_pattern" ]; then
  test_step25_has_identifier_pattern || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_parser_exclusions" ]; then
  test_step25_has_parser_exclusions || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_has_self_exclusion" ]; then
  test_step25_has_self_exclusion || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_scopes_production_dirs" ]; then
  test_step25_scopes_production_dirs || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_scopes_code_extensions" ]; then
  test_step25_scopes_code_extensions || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_uses_gitignore_filter" ]; then
  test_step25_uses_gitignore_filter || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_rambytes" ]; then
  test_step25_behavioral_rejects_rambytes || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_gib_literal" ]; then
  test_step25_behavioral_rejects_gib_literal || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_mib_literal" ]; then
  test_step25_behavioral_rejects_mib_literal || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_port" ]; then
  test_step25_behavioral_rejects_port || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_kb" ]; then
  test_step25_behavioral_rejects_kb || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_identifier" ]; then
  test_step25_behavioral_rejects_identifier || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_accepts_sanctioned" ]; then
  test_step25_behavioral_accepts_sanctioned || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step25_behavioral_rejects_full_mode" ]; then
  test_step25_behavioral_rejects_full_mode || exit 1
fi
