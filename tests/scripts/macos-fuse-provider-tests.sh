#!/usr/bin/env bash
# Tests for src/scripts/lib/macos-fuse-provider.sh, the fuse-t provider
# fingerprint recorded next to the ntfs-3g build fingerprint.
#
# That digest is the only guard against provider drift: fuse-t is installed
# outside the Nix store, so /usr/local/lib/libfuse-t.dylib can be replaced with no
# repository change and no Nix change at all.  These cases drive the checked-in
# fixture tree (tests/fixtures/fuse-provider/) instead of the live /usr/local
# installation, which the suite must never touch.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/lib.sh"
FUSE_PROVIDER_LIB="$SCRIPT_DIR/../../src/scripts/lib/macos-fuse-provider.sh"
PROVIDER_FIXTURE="$SCRIPT_DIR/../fixtures/fuse-provider"

# provider_call <function> [args...]: run a library call in a fresh shell that
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

# seed_provider_root <parent_dir>: copy the fixture tree to <parent_dir>/provider
# and print the copy's path, so no case can disturb the checked-in fixtures.
#
# The printed path is NOT canonicalized: the library has to tolerate any spelling
# of the provider root, and the symlinked-spelling case below asserts exactly
# that.
seed_provider_root() {
  local parent_dir="$1"
  mkdir -p "$parent_dir/provider"
  cp -R "$PROVIDER_FIXTURE/." "$parent_dir/provider/"
  printf '%s\n' "$parent_dir/provider"
}

# assert_digest_rejects_missing <test_name> <relative_path>: remove one required
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

# The digest has to be a function of the provider's *content*, not of the path
# used to reach it: the guard compares it with a value recorded by an earlier
# activation, so a spelling change alone would otherwise rebuild the binary, and
# a symlinked /var (as $TMPDIR has on macOS) makes that the common case.
test_digest_is_independent_of_a_symlinked_root_spelling() {
  local work root canonical via_link first second rc_canonical=0 rc_link=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  canonical="$(CDPATH='' cd -- "$root" && pwd -P)"
  ln -sfn "$canonical" "$work/provider-link"
  via_link="$work/provider-link"
  first="$(provider_call fuse_provider_digest "$canonical")" || rc_canonical=$?
  second="$(provider_call fuse_provider_digest "$via_link")" || rc_link=$?
  rm -rf "$work"
  if [ "$rc_canonical" -eq 0 ] && [ "$rc_link" -eq 0 ] && [ "$first" = "$second" ]; then
    assert_pass "provider digest ignores a symlinked provider root spelling"
  else
    assert_fail "provider digest ignores a symlinked provider root spelling" \
      "rc=$rc_canonical/$rc_link canonical=[$first] via-link=[$second]"
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
  if cmp -s "$root/lib/libfuse-t-1.2.7.dylib" "$root/lib/libfuse-t-1.3.0.dylib"; then
    identical=true
  fi
  before="$(provider_call fuse_provider_digest "$root")" || rc_before=$?
  ln -sfn libfuse-t-1.3.0.dylib "$root/lib/libfuse-t.dylib"
  after="$(provider_call fuse_provider_digest "$root")" || rc_after=$?
  rm -rf "$work"
  if [ "$identical" = true ] && [ "$rc_before" -eq 0 ] && [ "$rc_after" -eq 0 ] && [ "$before" != "$after" ]; then
    assert_pass "provider digest changes when the library symlink is repointed"
  else
    assert_fail "provider digest changes when the library symlink is repointed" \
      "identical-bytes=$identical rc=$rc_before/$rc_after before=[$before] after=[$after]"
  fi
}

# fuse-t installs /usr/local/include/fuse as a symlink into its application
# support tree, so the walk has to follow the directory. The digest must still
# name the headers under include/fuse/ (the spelling the build compiles against)
# rather than under the link target, or the site of the tree would leak into the
# fingerprint.
test_digest_follows_a_symlinked_include_directory() {
  local work root real_digest link_digest edited rc_real=0 rc_link=0 rc_edited=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  real_digest="$(provider_call fuse_provider_digest "$root")" || rc_real=$?
  mkdir -p "$root/fuse-t/include"
  mv "$root/include/fuse" "$root/fuse-t/include/fuse"
  ln -s ../fuse-t/include/fuse "$root/include/fuse"
  link_digest="$(provider_call fuse_provider_digest "$root")" || rc_link=$?
  if [ "$rc_real" -eq 0 ] && [ "$rc_link" -eq 0 ] && [ "$real_digest" = "$link_digest" ]; then
    assert_pass "provider digest follows a symlinked include/fuse directory"
  else
    assert_fail "provider digest follows a symlinked include/fuse directory" \
      "rc=$rc_real/$rc_link real=[$real_digest] symlinked=[$link_digest]"
  fi

  printf '%s\n' '/* drift behind the link */' >>"$root/fuse-t/include/fuse/fuse_common.h"
  edited="$(provider_call fuse_provider_digest "$root")" || rc_edited=$?
  rm -rf "$work"
  if [ "$rc_edited" -eq 0 ] && [ "$edited" != "$link_digest" ]; then
    assert_pass "provider digest changes when a header behind the symlink changes"
  else
    assert_fail "provider digest changes when a header behind the symlink changes" \
      "rc=$rc_edited before=[$link_digest] after=[$edited]"
  fi
}

# A dangling include/fuse link is the shape left by a half-removed provider: the
# build cannot compile against it, so the digest must refuse rather than hash a
# library and a pkg-config file that happen to survive.
test_digest_rejects_a_dangling_include_symlink() {
  local work root out rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  rm -rf "$root/include/fuse"
  ln -s ../absent/include/fuse "$root/include/fuse"
  out="$(provider_call fuse_provider_digest "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "provider digest rejects a dangling include/fuse symlink"
  else
    assert_fail "provider digest rejects a dangling include/fuse symlink" "rc=$rc stdout=[$out]"
  fi
}

test_digest_rejects_incomplete_providers() {
  assert_digest_rejects_missing "provider digest rejects missing fuse-t headers" "include/fuse/fuse.h"
  assert_digest_rejects_missing "provider digest rejects a missing provider library" "lib/libfuse-t.dylib"
  assert_digest_rejects_missing "provider digest rejects a missing pkg-config file" "lib/pkgconfig/fuse-t.pc"
}

# A provider file that exists but cannot be read must fail the digest: an empty
# hash would record a fingerprint over contents that were never read.
test_digest_rejects_an_unreadable_provider_file() {
  local work root out rc=0
  if [ "$(id -u)" -eq 0 ]; then
    # WHY: root bypasses mode bits, so a chmod 000 provider file stays readable and
    #   this host cannot construct the precondition. Asserting the host property
    #   keeps the case visible instead of reporting a check that never ran.
    assert_pass "provider digest rejects an unreadable provider file (unconstructible as root: root reads mode 000)"
    return 0
  fi
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  chmod 000 "$root/include/fuse/fuse_common.h"
  out="$(provider_call fuse_provider_digest "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "provider digest rejects an unreadable provider file"
  else
    assert_fail "provider digest rejects an unreadable provider file" "rc=$rc stdout=[$out]"
  fi
}

test_lib_name_follows_the_provider_symlink() {
  local work root name repointed rc_name=0 rc_repointed=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  name="$(provider_call fuse_provider_lib_name "$root")" || rc_name=$?
  ln -sfn libfuse-t-1.3.0.dylib "$root/lib/libfuse-t.dylib"
  repointed="$(provider_call fuse_provider_lib_name "$root")" || rc_repointed=$?
  rm -rf "$work"

  if [ "$rc_name" -eq 0 ] && [ "$name" = "libfuse-t-1.2.7.dylib" ]; then
    assert_pass "provider library name follows the fuse-t symlink"
  else
    assert_fail "provider library name follows the fuse-t symlink" "rc=$rc_name name=[$name]"
  fi
  if [ "$rc_repointed" -eq 0 ] && [ "$repointed" = "libfuse-t-1.3.0.dylib" ]; then
    assert_pass "provider library name follows a repointed fuse-t symlink"
  else
    assert_fail "provider library name follows a repointed fuse-t symlink" "rc=$rc_repointed name=[$repointed]"
  fi
}

test_identity_names_version_and_library() {
  local work root identity rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  identity="$(provider_call fuse_provider_identity "$root" 9.9.9)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -eq 0 ] && [ "$identity" = "fuset 9.9.9 libfuse-t-1.2.7.dylib" ]; then
    assert_pass "provider identity names the fuse-t version and resolved library"
  else
    assert_fail "provider identity names the fuse-t version and resolved library" "rc=$rc output=[$identity]"
  fi
}

test_provider_version_reads_the_version_line() {
  local work root version rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  version="$(provider_call fuse_provider_version "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -eq 0 ] && [ "$version" = "1.2.7" ]; then
    assert_pass "provider version reads the pkg-config version line"
  else
    assert_fail "provider version reads the pkg-config version line" "rc=$rc stdout=[$version]"
  fi
}

test_provider_version_fails_without_a_version_line() {
  local work root out rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  printf '%s\n' 'Name: fuse-t' >"$root/lib/pkgconfig/fuse-t.pc"
  out="$(provider_call fuse_provider_version "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "provider version fails when the pkg-config file carries no version line"
  else
    assert_fail "provider version fails when the pkg-config file carries no version line" "rc=$rc stdout=[$out]"
  fi
}

test_provider_version_fails_when_the_pkgconfig_file_is_missing() {
  local work root out rc=0
  work="$(mktemp -d)"
  root="$(seed_provider_root "$work")"
  rm -f "$root/lib/pkgconfig/fuse-t.pc"
  out="$(provider_call fuse_provider_version "$root" 2>/dev/null)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    assert_pass "provider version fails when the pkg-config file is missing"
  else
    assert_fail "provider version fails when the pkg-config file is missing" "rc=$rc stdout=[$out]"
  fi
}

# ---- Build record fields ----

test_record_field_reads_the_requested_line() {
  local work record first second third rc_first=0 rc_second=0 rc_third=0
  work="$(mktemp -d)"
  record="$work/.build-fingerprint"
  printf '%s\n' "nix-fingerprint-value" "provider-digest-value" "fuset 1.2.7 libfuse-t-1.2.7.dylib" >"$record"
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
  if [ "$rc_third" -eq 0 ] && [ "$third" = "fuset 1.2.7 libfuse-t-1.2.7.dylib" ]; then
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

# The build record and the pkg-config version line are read on every platform, so
# those cases always run: neither needs /bin/realpath.
test_record_field_reads_the_requested_line
test_record_field_rejects_a_missing_record
test_record_field_reports_an_absent_line_for_legacy_records
test_provider_version_reads_the_version_line
test_provider_version_fails_without_a_version_line
test_provider_version_fails_when_the_pkgconfig_file_is_missing

# The provider helpers resolve the provider library with /bin/realpath, so these
# cases run wherever that path exists: macOS, and any Linux whose /bin is the
# usr-merge (Ubuntu CI included). Where it does not (NixOS keeps no /bin beyond
# /bin/sh), the helper cannot run at all, and the product is macOS-only (fuse-t),
# so the cases name that absence explicitly rather than standing aside.
# Gate on the capability, not on the OS: an OS gate would have kept these cases
# silent on Linux CI, which is where a regression in the digest would land unseen.
if [ -x /bin/realpath ]; then
  test_digest_is_stable_and_root_independent
  test_digest_is_independent_of_a_symlinked_root_spelling
  test_digest_changes_when_a_header_changes
  test_digest_changes_when_the_library_symlink_is_repointed
  test_digest_follows_a_symlinked_include_directory
  test_digest_rejects_a_dangling_include_symlink
  test_digest_rejects_incomplete_providers
  test_digest_rejects_an_unreadable_provider_file
  test_lib_name_follows_the_provider_symlink
  test_identity_names_version_and_library
else
  for _case in \
    "provider digest is a sha256 and is stable across calls" \
    "provider digest ignores where the provider root lives" \
    "provider digest ignores a symlinked provider root spelling" \
    "provider digest changes when a header changes" \
    "provider digest changes when the library symlink is repointed" \
    "provider digest follows a symlinked include/fuse directory" \
    "provider digest changes when a header behind the symlink changes" \
    "provider digest rejects a dangling include/fuse symlink" \
    "provider digest rejects missing fuse-t headers" \
    "provider digest rejects a missing provider library" \
    "provider digest rejects a missing pkg-config file" \
    "provider digest rejects an unreadable provider file" \
    "provider library name follows the fuse-t symlink" \
    "provider library name follows a repointed fuse-t symlink" \
    "provider identity names the fuse-t version and resolved library"; do
    assert_pass "$_case (not exercisable: no /bin/realpath on $(uname -s); fuse-t provider is macOS-only)"
  done
fi

finish_tests
