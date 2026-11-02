#!/usr/bin/env bash
# Tests for the rebuild gate and the fuse-t wiring in
# src/hosts/MacBook/scripts/macos-build-ntfs3g.sh.
#
# The gate is what makes the Nix fingerprint and the provider digest effective: a
# wrong comparison either rebuilds on every activation or keeps an installed
# binary that no longer matches the sources or the provider it links against.
# The decision table is exercised against fixture state by extracting the gate
# from the activation script; the script body is never executed, because it builds
# and installs into /usr/local. The provider fingerprint itself is covered by
# tests/scripts/macos-fuse-provider-tests.sh, next to the library that holds it;
# this suite only asserts that the script is wired to that one implementation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
FUSE_PROVIDER_LIB="$SCRIPT_DIR/../../src/scripts/lib/macos-fuse-provider.sh"
BUILD_SCRIPT="$SCRIPT_DIR/../../src/hosts/MacBook/scripts/macos-build-ntfs3g.sh"

FINGERPRINT="3f1a9c1d0b7e4a5f8c2d6e9b0a1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f70819"
OTHER_FINGERPRINT="0000000000000000000000000000000000000000000000000000000000000000"
DIGEST="9c2f8b0a1d3e4f5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c"
OTHER_DIGEST="1111111111111111111111111111111111111111111111111111111111111111"
PROVIDER_IDENTITY="fuset 1.2.7 libfuse-t-1.2.7.dylib"

assert_contains() { # <name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "expected [$3], got: $2" ;;
  esac
}

assert_not_contains() { # <name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_fail "$1" "expected no [$3], got: $2" ;;
  *) assert_pass "$1" ;;
  esac
}

# Fail closed: a renamed gate would make every case below assert an empty reason,
# and the "no rebuild" case would then pass while nothing was exercised.
GATE_FUNC="$(extract_func ntfs3g_rebuild_reason "$BUILD_SCRIPT")"
if [ -z "$GATE_FUNC" ]; then
  assert_fail "rebuild gate is defined in the build script" \
    "extract_func ntfs3g_rebuild_reason returned nothing from $BUILD_SCRIPT"
  finish_tests
fi

BUILD_SCRIPT_TEXT="$(<"$BUILD_SCRIPT")"

# ---- Provider retarget ----

# The link consumes fuse-t, and fuse-t installs libfuse-t.dylib next to a static
# libfuse-t.a with no .la, so the script has to name the dylib itself.
assert_contains "build script links fuse-t" "$BUILD_SCRIPT_TEXT" "libfuse-t"
assert_not_contains "build script names no macFUSE library" "$BUILD_SCRIPT_TEXT" "lib/libfuse.dylib"
# -o backend=fskit is a macFUSE FSKit selector; fuse-t mounts through its own
# default backend and this host registers no file system extension at all.
assert_not_contains "build script passes no macFUSE backend flag" "$BUILD_SCRIPT_TEXT" "backend=fskit"
# The macFUSE installer receipt cannot identify a fuse-t install, so nothing may
# still ask pkgutil for it.
assert_not_contains "build script reads no macFUSE receipt" "$BUILD_SCRIPT_TEXT" "io.macfuse.installer.components.core"

# The provider fingerprint lives in one place. A private copy in the build script
# drifts from the library its own suite covers, and the build script is what
# activation actually runs, so the wiring is asserted rather than inferred.
assert_contains "build script sources the fuse-t provider helper" "$BUILD_SCRIPT_TEXT" "scripts/lib/macos-fuse-provider.sh"
assert_contains "build script computes the provider digest from the helper" "$BUILD_SCRIPT_TEXT" "fuse_provider_digest \"\$PROVIDER_ROOT\""
assert_contains "build script reads the provider version from the helper" "$BUILD_SCRIPT_TEXT" "fuse_provider_version \"\$PROVIDER_ROOT\""
assert_contains "build script names the provider from the helper" "$BUILD_SCRIPT_TEXT" "fuse_provider_identity \"\$PROVIDER_ROOT\""
assert_contains "build script reads the build record through the provider helper" "$BUILD_SCRIPT_TEXT" "fuse_provider_record_field 1 \"\$2\""
assert_not_contains "build script carries no private record reader" "$BUILD_SCRIPT_TEXT" "sed -n 1p"
assert_not_contains "build script carries no private provider digest" "$BUILD_SCRIPT_TEXT" "ntfs3g_provider_digest"
assert_not_contains "build script carries no private provider identity" "$BUILD_SCRIPT_TEXT" "ntfs3g_provider_identity"

# Fail closed: without the fuse-t absence gate the script hard-errors on a host
# that intentionally runs without fuse-t, and every apply aborts at the ntfs-3g
# build step.
if grep -qF -- 'build skipped: fuse-t absent' "$BUILD_SCRIPT" &&
  grep -qF -- "if ! [ -f \"\$PROVIDER_LIB\" ]; then" "$BUILD_SCRIPT"; then
  assert_pass "fuse-t absence gate skips with a notice"
else
  assert_fail "fuse-t absence gate skips with a notice" "the PROVIDER_LIB absence check or its notice line is missing from $BUILD_SCRIPT"
fi

# ---- Rebuild gate ----

# gate_call <function_text> <binary> <record> <fingerprint> <digest>: run the
# extracted gate in a fresh shell that also sources lib.sh and the provider
# library the gate delegates to.
# Prints the rebuild reason (empty when the installed binary is current).
gate_call() {
  local function_text="$1"
  shift
  bash -c '
    . "$1"
    . "$2"
    eval "$3"
    shift 3
    ntfs3g_rebuild_reason "$@"
  ' macos-build-ntfs3g-tests "$LIB_SH" "$FUSE_PROVIDER_LIB" "$function_text" "$@"
}

# assert_reason <test_name> <expected_reason> <binary> <record> <fingerprint> <digest>
assert_reason() {
  local test_name="$1" expected="$2" actual
  shift 2
  actual="$(gate_call "$GATE_FUNC" "$@")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual]"
  fi
}

test_gate_reports_every_rebuild_reason() {
  local work binary record
  work="$(mktemp -d)"
  binary="$work/binary"
  printf '#!/bin/sh\n' >"$binary"
  chmod +x "$binary"
  record="$work/record"
  printf '%s\n%s\n%s\n' "$FINGERPRINT" "$DIGEST" "$PROVIDER_IDENTITY" >"$record"

  assert_reason "rebuild gate rebuilds when the installed binary is missing" \
    "binary missing" "$work/absent" "$record" "$FINGERPRINT" "$DIGEST"
  assert_reason "rebuild gate rebuilds when the record is missing" \
    "build record missing" "$binary" "$work/absent-record" "$FINGERPRINT" "$DIGEST"
  assert_reason "rebuild gate rebuilds when the Nix fingerprint changed" \
    "build configuration changed" "$binary" "$record" "$OTHER_FINGERPRINT" "$DIGEST"
  assert_reason "rebuild gate rebuilds when the provider digest changed" \
    "fuse-t provider changed" "$binary" "$record" "$FINGERPRINT" "$OTHER_DIGEST"
  assert_reason "rebuild gate reports a current install as needing no rebuild" \
    "" "$binary" "$record" "$FINGERPRINT" "$DIGEST"

  rm -rf "$work"
}

test_gate_rebuilds_when_the_installed_binary_is_not_executable() {
  local work binary record
  work="$(mktemp -d)"
  binary="$work/not-executable"
  printf '#!/bin/sh\n' >"$binary"
  chmod -x "$binary"
  record="$work/record"
  printf '%s\n%s\n%s\n' "$FINGERPRINT" "$DIGEST" "$PROVIDER_IDENTITY" >"$record"

  assert_reason "rebuild gate rebuilds when the installed binary is not executable" \
    "binary missing" "$binary" "$record" "$FINGERPRINT" "$DIGEST"

  rm -rf "$work"
}

test_gate_rebuilds_on_a_legacy_one_line_record() {
  local work binary record
  work="$(mktemp -d)"
  binary="$work/binary"
  printf '#!/bin/sh\n' >"$binary"
  chmod +x "$binary"
  # A record written before the provider digest existed carries the fingerprint
  # only.  Its missing second line has to read as a provider mismatch, which is
  # what rebuilds such an install exactly once instead of never.
  record="$work/legacy-record"
  printf '%s\n' "$FINGERPRINT" >"$record"

  assert_reason "rebuild gate rebuilds on a record without a provider digest" \
    "fuse-t provider changed" "$binary" "$record" "$FINGERPRINT" "$DIGEST"

  rm -rf "$work"
}

# ---- Cases ----

test_gate_reports_every_rebuild_reason
test_gate_rebuilds_when_the_installed_binary_is_not_executable
test_gate_rebuilds_on_a_legacy_one_line_record

finish_tests
