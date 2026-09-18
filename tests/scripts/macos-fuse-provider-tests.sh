#!/usr/bin/env bash
# Tests for src/scripts/lib/macos-fuse-provider.sh — the macFUSE provider
# fingerprint recorded next to the ntfs-3g build fingerprint.
#
# That digest is the only guard against provider drift: macFUSE is installed by a
# Homebrew cask that declares auto_updates, so /usr/local/lib/libfuse.dylib can
# be replaced with no repository change and no Nix change at all.  These cases
# drive the checked-in fixture tree (tests/fixtures/fuse-provider/) instead of the
# live /usr/local installation, which the suite must never touch.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
FUSE_PROVIDER_LIB="$SCRIPT_DIR/../../src/scripts/lib/macos-fuse-provider.sh"
PROVIDER_FIXTURE="$SCRIPT_DIR/../fixtures/fuse-provider"

# provider_call <function> [args...] — run a library call in a fresh shell that
# sources lib.sh (sha256_of_file, error) and the provider library first.  The
# subshell keeps the suite's set -euo pipefail from interacting with functions
# whose whole contract is their exit status, and keeps the library's globals out
# of the suite's own shell.
provider_call() {
  local function_name="$1"
  shift
  bash -c '
    . "$1"
    . "$2"
    shift 2
    "$@"
  ' macos-fuse-provider-tests "$LIB_SH" "$FUSE_PROVIDER_LIB" "$function_name" "$@"
}

# seed_provider_root <parent_dir> — copy the fixture tree to <parent_dir>/provider
# and print the copy's path, so no case can disturb the checked-in fixtures.
#
# The printed path is canonical because the library resolves the provider library
# with /bin/realpath: an unresolved root spelling (/var vs /private/var on macOS)
# would leak an absolute library path into the digest manifest, which the
# root-independence case below would then read as a difference.
seed_provider_root() {
  local parent_dir="$1"
  mkdir -p "$parent_dir/provider"
  cp -R "$PROVIDER_FIXTURE/." "$parent_dir/provider/"
  (CDPATH='' cd -- "$parent_dir/provider" && pwd -P)
}

# assert_digest_rejects_missing <test_name> <relative_path> — remove one required
# provider file in a fresh copy and require the digest to refuse a value: a
# partial provider must fail loudly rather than fingerprint a truncated tree.
assert_digest_rejects_missing() {
  local test_name="$1" relative_path="$2" work root rc=0 out
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  rm -rf "${root:?}/$relative_path"
  out="$(provider_call fuse_provider_digest "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "after removing $relative_path: rc=$rc stdout=[$out]"
  fi
}

# ---- Provider digest ----

test_digest_is_stable_and_root_independent() {
  local work root_a root_b first second other rc_first=0 rc_second=0 rc_other=0
  work="$(mktemp -d)"
  root_a="$(seed_provider_root "$work/a")"
  root_b="$(seed_provider_root "$work/b")"
  first="$(provider_call fuse_provider_digest "$root_a")" || rc_first=$?
  second="$(provider_call fuse_provider_digest "$root_a")" || rc_second=$?
  other="$(provider_call fuse_provider_digest "$root_b")" || rc_other=$?
  rm -rf "$work"

  if [ "$rc_first" -eq 0 ] && [ "$rc_second" -eq 0 ] &&
    printf '%s' "$first" | grep -Eq '^[0-9a-f]{64}$' &&
    [ "$first" = "$second" ]; then
    assert_pass "provider digest is a sha256 and is stable across calls"
  else
    assert_fail "provider digest is a sha256 and is stable across calls" \
      "rc=$rc_first/$rc_second first=[$first] second=[$second]"
  fi

  if [ "$rc_other" -eq 0 ] && [ "$other" = "$first" ]; then
    assert_pass "provider digest ignores where the provider root lives"
  else
    assert_fail "provider digest ignores where the provider root lives" \
      "rc=$rc_other other=[$other] expected=[$first]"
  fi
}

test_digest_changes_when_a_header_changes() {
  local work root before after rc_before=0 rc_after=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  before="$(provider_call fuse_provider_digest "$root")" || rc_before=$?
  # fuse_common.h, not fuse.h: the mutation has to prove the whole include/fuse/
  # directory is covered, not just the header the library checks for existence.
  printf '%s\n' '/* fixture drift */' >>"$root/include/fuse/fuse_common.h"
  after="$(provider_call fuse_provider_digest "$root")" || rc_after=$?
  rm -rf "$work"
  if [ "$rc_before" -eq 0 ] && [ "$rc_after" -eq 0 ] && [ "$before" != "$after" ]; then
    assert_pass "provider digest changes when a header changes"
  else
    assert_fail "provider digest changes when a header changes" \
      "rc=$rc_before/$rc_after before=[$before] after=[$after]"
  fi
}

test_digest_changes_when_the_library_symlink_is_repointed() {
  local work root before after identical=false rc_before=0 rc_after=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  # The case is only meaningful while both ABI files hold identical bytes; assert
  # that here so an edit to one fixture cannot silently weaken it.
  if cmp -s "$root/lib/libfuse.2.dylib" "$root/lib/libfuse.3.dylib"; then
    identical=true
  fi
  before="$(provider_call fuse_provider_digest "$root")" || rc_before=$?
  ln -sfn libfuse.3.dylib "$root/lib/libfuse.dylib"
  after="$(provider_call fuse_provider_digest "$root")" || rc_after=$?
  rm -rf "$work"
  if [ "$identical" = true ] && [ "$rc_before" -eq 0 ] && [ "$rc_after" -eq 0 ] && [ "$before" != "$after" ]; then
    assert_pass "provider digest changes when the library symlink is repointed"
  else
    assert_fail "provider digest changes when the library symlink is repointed" \
      "identical-bytes=$identical rc=$rc_before/$rc_after before=[$before] after=[$after]"
  fi
}

test_digest_rejects_incomplete_providers() {
  assert_digest_rejects_missing "provider digest rejects missing fuse headers" "include/fuse/fuse.h"
  assert_digest_rejects_missing "provider digest rejects a missing provider library" "lib/libfuse.dylib"
  assert_digest_rejects_missing "provider digest rejects a missing pkg-config file" "lib/pkgconfig/fuse.pc"
}

test_lib_name_follows_the_provider_symlink() {
  local work root name repointed rc_name=0 rc_repointed=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  name="$(provider_call fuse_provider_lib_name "$root")" || rc_name=$?
  ln -sfn libfuse.3.dylib "$root/lib/libfuse.dylib"
  repointed="$(provider_call fuse_provider_lib_name "$root")" || rc_repointed=$?
  rm -rf "$work"

  if [ "$rc_name" -eq 0 ] && [ "$name" = "libfuse.2.dylib" ]; then
    assert_pass "provider library name follows the macFUSE symlink"
  else
    assert_fail "provider library name follows the macFUSE symlink" "rc=$rc_name name=[$name]"
  fi
  if [ "$rc_repointed" -eq 0 ] && [ "$repointed" = "libfuse.3.dylib" ]; then
    assert_pass "provider library name follows a repointed macFUSE symlink"
  else
    assert_fail "provider library name follows a repointed macFUSE symlink" "rc=$rc_repointed name=[$repointed]"
  fi
}

test_identity_names_version_and_library() {
  local work root identity rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  identity="$(provider_call fuse_provider_identity "$root" 9.9.9)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -eq 0 ] && [ "$identity" = "macfuse 9.9.9 libfuse.2.dylib" ]; then
    assert_pass "provider identity names the macFUSE version and resolved library"
  else
    assert_fail "provider identity names the macFUSE version and resolved library" "rc=$rc output=[$identity]"
  fi
}

test_macfuse_pkg_version_contract() {
  local rc=0 version expected
  require_command /usr/sbin/pkgutil "macfuse_pkg_version reads /usr/sbin/pkgutil --pkg-info"
  version="$(provider_call macfuse_pkg_version 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$version" ]; then
    expected="$(/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core | awk '/^version:/ { print $2 }')"
    if [ "$version" = "$expected" ]; then
      assert_pass "macfuse_pkg_version reports the installed receipt version"
    else
      assert_fail "macfuse_pkg_version reports the installed receipt version" "reported=[$version] receipt=[$expected]"
    fi
  elif [ "$rc" -ne 0 ] && [ -z "$version" ]; then
    # Host without macFUSE: the wrapper must fail loudly instead of inventing a
    # version, because a provider that cannot be identified is exactly the state
    # the build record exists to expose.
    assert_pass "macfuse_pkg_version fails loudly when the receipt is absent"
  else
    assert_fail "macfuse_pkg_version receipt contract" "rc=$rc stdout=[$version]"
  fi
}

# ---- Build record fields ----

test_record_field_reads_the_requested_line() {
  local work record first second third rc_first=0 rc_second=0 rc_third=0
  work="$(mktemp -d)"
  record="$work/.build-fingerprint"
  printf '%s\n' "nix-fingerprint-value" "provider-digest-value" "macfuse 9.9.9 libfuse.2.dylib" >"$record"
  first="$(provider_call fuse_provider_record_field 1 "$record")" || rc_first=$?
  second="$(provider_call fuse_provider_record_field 2 "$record")" || rc_second=$?
  third="$(provider_call fuse_provider_record_field 3 "$record")" || rc_third=$?
  rm -rf "$work"

  if [ "$rc_first" -eq 0 ] && [ "$first" = "nix-fingerprint-value" ]; then
    assert_pass "record field 1 is the Nix build fingerprint"
  else
    assert_fail "record field 1 is the Nix build fingerprint" "rc=$rc_first field=[$first]"
  fi
  if [ "$rc_second" -eq 0 ] && [ "$second" = "provider-digest-value" ]; then
    assert_pass "record field 2 is the provider digest"
  else
    assert_fail "record field 2 is the provider digest" "rc=$rc_second field=[$second]"
  fi
  if [ "$rc_third" -eq 0 ] && [ "$third" = "macfuse 9.9.9 libfuse.2.dylib" ]; then
    assert_pass "record field 3 is the provider identity"
  else
    assert_fail "record field 3 is the provider identity" "rc=$rc_third field=[$third]"
  fi
}

test_record_field_rejects_a_missing_record() {
  local work record out rc=0
  work="$(mktemp -d)"
  record="$work/.build-fingerprint"
  out="$(provider_call fuse_provider_record_field 2 "$record" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "record field reports a missing build record as a failure"
  else
    assert_fail "record field reports a missing build record as a failure" "rc=$rc stdout=[$out]"
  fi
}

test_record_field_reports_an_absent_line_for_legacy_records() {
  local work record out rc=0
  work="$(mktemp -d)"
  record="$work/.build-fingerprint"
  # A record written before the provider digest existed carries one line; the
  # caller must see the provider field as empty (a mismatch) rather than as an
  # error, so the rebuild decision stays a plain string comparison.
  printf '%s\n' "nix-fingerprint-value" >"$record"
  out="$(provider_call fuse_provider_record_field 2 "$record")" || rc=$?
  rm -rf "$work"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "record field 2 of a legacy one-line record is empty"
  else
    assert_fail "record field 2 of a legacy one-line record is empty" "rc=$rc stdout=[$out]"
  fi
}

# ---- Run all tests ----

# The build record is read on every platform, so those cases always run.
test_record_field_reads_the_requested_line
test_record_field_rejects_a_missing_record
test_record_field_reports_an_absent_line_for_legacy_records

# The provider itself is macOS-only: the library resolves the provider library
# with /bin/realpath and reads the package receipt with /usr/sbin/pkgutil.
if [ "$(uname -s)" != "Darwin" ]; then
  assert_skip "provider digest is a sha256 and is stable across calls" "macOS-only /bin/realpath"
  assert_skip "provider digest ignores where the provider root lives" "macOS-only /bin/realpath"
  assert_skip "provider digest changes when a header changes" "macOS-only /bin/realpath"
  assert_skip "provider digest changes when the library symlink is repointed" "macOS-only /bin/realpath"
  assert_skip "provider digest rejects missing fuse headers" "macOS-only /bin/realpath"
  assert_skip "provider digest rejects a missing provider library" "macOS-only /bin/realpath"
  assert_skip "provider digest rejects a missing pkg-config file" "macOS-only /bin/realpath"
  assert_skip "provider library name follows the macFUSE symlink" "macOS-only /bin/realpath"
  assert_skip "provider library name follows a repointed macFUSE symlink" "macOS-only /bin/realpath"
  assert_skip "provider identity names the macFUSE version and resolved library" "macOS-only /bin/realpath"
  assert_skip "macfuse_pkg_version receipt contract" "macOS-only /usr/sbin/pkgutil"
else
  test_digest_is_stable_and_root_independent
  test_digest_changes_when_a_header_changes
  test_digest_changes_when_the_library_symlink_is_repointed
  test_digest_rejects_incomplete_providers
  test_lib_name_follows_the_provider_symlink
  test_identity_names_version_and_library
  test_macfuse_pkg_version_contract
fi

finish_tests
