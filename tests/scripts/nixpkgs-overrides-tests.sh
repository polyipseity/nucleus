#!/usr/bin/env bash
# Tests for the temporary nixpkgs override mechanism (nixpkgs-next).
# Run with: bash tests/scripts/nixpkgs-overrides-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
OVERRIDES="$REPO_ROOT/src/modules/packages/nixpkgs-overrides.nix"
INSTRUCTION="$REPO_ROOT/.agents/instructions/nixpkgs-overrides.instructions.md"

_t_override_file_exists() {
  if [ -f "$OVERRIDES" ]; then
    assert_pass "nixpkgs-overrides.nix exists"
  else
    assert_fail "nixpkgs-overrides.nix exists" "missing $OVERRIDES"
  fi
}

_t_mechanism_header_present() {
  local ok=1
  grep -q 'TEMPORARY nixpkgs overrides' "$OVERRIDES" || ok=0
  grep -q 'nixpkgs-next' "$OVERRIDES" || ok=0
  grep -q 'nixpkgs-overrides.instructions.md' "$OVERRIDES" || ok=0
  grep -q 'Build and validation' "$OVERRIDES" || ok=0
  grep -q 'stay in the tree even when empty' "$OVERRIDES" || ok=0
  if [ "$ok" -eq 1 ]; then
    assert_pass "nixpkgs-overrides.nix keeps the mechanism/discovery/removal header"
  else
    assert_fail "nixpkgs-overrides.nix header" "missing required discovery or removal text"
  fi
}

_t_imported_by_flake() {
  if grep -q 'nixpkgs-overrides.nix' "$REPO_ROOT/src/flake.nix"; then
    assert_pass "src/flake.nix imports the nixpkgs overrides module"
  else
    assert_fail "src/flake.nix imports nixpkgs-overrides.nix" "not referenced from src/flake.nix"
  fi
}

_t_discovery_points_present() {
  local ok=1
  [ -f "$INSTRUCTION" ] || ok=0
  grep -q 'nixpkgs-overrides.instructions.md' "$REPO_ROOT/AGENTS.md" || ok=0
  grep -q 'nixpkgs-overrides' "$REPO_ROOT/src/flake.nix" || ok=0
  grep -q 'nixpkgs-overrides' "$OVERRIDES" || ok=0
  if [ "$ok" -eq 1 ]; then
    assert_pass "all discovery points reference nixpkgs-overrides"
  else
    assert_fail "discovery points" "missing instruction, AGENTS bullet, or source reference"
  fi
}

# Each non-comment overlay entry must carry TEMPORARY, REMOVE WHEN, and WHY markers.
# An entry is a line assigning a package attr inside the overlay body (name = ...;).
# Comment-only and structural lines are ignored, so an empty overlay is valid.
_t_entries_have_required_markers() {
  local in_overlay=0
  local markers=""
  local line
  local failed=0
  local entry_line=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    *'overlay = '*)
      in_overlay=1
      markers=""
      continue
      ;;
    esac
    [ "$in_overlay" -eq 1 ] || continue

    # End of overlay attrset (closing brace of the overlay value at module indent).
    if printf '%s\n' "$line" | grep -Eq '^  \};[[:space:]]*$'; then
      break
    fi

    case "$line" in
    *'# TEMPORARY'*)
      markers="${markers}T"
      ;;
    *'# REMOVE WHEN'*)
      markers="${markers}R"
      ;;
    *'# WHY'*)
      markers="${markers}W"
      ;;
    esac

    # A package entry is an assignment inside the overlay body (indented).
    if printf '%s\n' "$line" | grep -Eq '^[[:space:]]+[A-Za-z0-9._+-]+[[:space:]]*='; then
      # Ignore the overlay's own structural assignments if any appear oddly; package
      # entries live under the overlay body and are not comment lines.
      case "$markers" in
      *T*R*W* | *T*W*R* | *R*T*W* | *R*W*T* | *W*T*R* | *W*R*T*) ;;
      *)
        failed=1
        entry_line="$line"
        ;;
      esac
      markers=""
    fi
  done <"$OVERRIDES"

  if [ "$failed" -eq 0 ]; then
    assert_pass "every nixpkgs override entry has TEMPORARY, REMOVE WHEN, and WHY markers"
  else
    assert_fail "override entry markers" "missing required markers near: $entry_line"
  fi
}

_t_override_file_exists
_t_mechanism_header_present
_t_imported_by_flake
_t_discovery_points_present
_t_entries_have_required_markers

finish_tests
