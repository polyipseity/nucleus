#!/usr/bin/env bash
# mount-backend-{linux,darwin}.sh — backend_probe_state answers about MOUNT
# STATE, never content, and keeps the undeterminable answer. The two backends
# reach that answer from different evidence, so both are exercised here: the
# Linux one from a mount table, the darwin one from a query that cannot run.
#
# The regression this guards is D54: the probe used to require a non-empty
# directory, so a mounted-but-empty remote root (a freshly created cloud folder)
# read as "not mounted". The runner then never set live, exhausted its attempts,
# and left the service permanently blocked on a mount that had actually
# succeeded. The inverse error matters just as much: a NON-empty directory that
# is not a mount must not read as mounted, or the runner would skip a genuine
# revival. Both directions are asserted below, plus the case boundary (a mount
# point that is a string prefix of a mounted path is not itself mounted) and the
# third value, which is the one the two-valued predicate cannot express.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state
# shellcheck source=../../src/scripts/lib/mount-backend-linux.sh
. "$SCRIPT_DIR/../../src/scripts/lib/mount-backend-linux.sh"

# The probe reads the host mount state through `mount`. A shim on PATH supplies a
# table the test controls, so the mounted-empty case can be exercised at all —
# a real empty mount would need a real FUSE mount, which a suite must not create.
_shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/mbp-shim.XXXXXX")"
_table="$(mktemp "${TMPDIR:-/tmp}/mbp-table.XXXXXX")"
trap 'rm -rf "$_shim_dir" "$_table"' EXIT

cat >"$_shim_dir/mount" <<'SHIM'
#!/bin/sh
cat "$MOCK_MOUNT_TABLE"
SHIM
chmod +x "$_shim_dir/mount"
export MOCK_MOUNT_TABLE="$_table"
PATH="$_shim_dir:$PATH"

_work="$(mktemp -d "${TMPDIR:-/tmp}/mbp-work.XXXXXX")"
trap 'rm -rf "$_shim_dir" "$_table" "$_work"' EXIT

_mounted_empty="$_work/mounted-empty"
_mounted_full="$_work/mounted-full"
_plain_dir="$_work/plain-dir"
_prefix_sibling="$_work/prefix"
mkdir -p "$_mounted_empty" "$_mounted_full" "$_plain_dir" "$_prefix_sibling"
: >"$_mounted_full/an-entry"
: >"$_plain_dir/an-entry"
mkdir -p "$_prefix_sibling-sibling"

# Mount table: only the two "mounted" paths are present. `_plain_dir` is
# deliberately NON-empty so the content heuristic would wrongly call it mounted.
cat >"$_table" <<TABLE
/dev/sda1 on / (ext4, rw, relatime)
fakefs on $_mounted_empty (fuse.rclone, rw)
fakefs on $_mounted_full (fuse.rclone, rw)
fakefs on $_prefix_sibling-sibling (fuse.rclone, rw)
TABLE

probe_state() { # <path>
  backend_probe_state "$1"
}

# ── D54 regression: mounted but EMPTY must read as mounted ───────────────────
case "$(probe_state "$_mounted_empty")" in
present) assert_pass "a mounted-but-empty mount point reads as mounted" ;;
*) assert_fail "mount-probe-empty-mounted" \
  "an empty mounted remote root read as not mounted ([$(probe_state "$_mounted_empty")]) — D54" ;;
esac

# ── mounted and non-empty stays mounted ──────────────────────────────────────
case "$(probe_state "$_mounted_full")" in
present) assert_pass "a mounted-and-non-empty mount point reads as mounted" ;;
*) assert_fail "mount-probe-nonempty-mounted" "[$(probe_state "$_mounted_full")]" ;;
esac

# ── inverse error: a NON-empty directory that is not mounted is NOT mounted ──
# The token is the full one, not merely "not present": a table that was read and
# lists other paths is an answer, and the case that follows asserts the answer
# for a table nobody could read is a different one.
case "$(probe_state "$_plain_dir")" in
absent:not-listed) assert_pass "a non-empty directory that is not mounted reads as not mounted" ;;
*) assert_fail "mount-probe-nonempty-unmounted" \
  "a non-empty unmounted directory read as mounted ([$(probe_state "$_plain_dir")]) — revival would be skipped" ;;
esac

# ── a missing path is not mounted ────────────────────────────────────────────
case "$(probe_state "$_work/absent")" in
absent:not-listed) assert_pass "a missing mount point reads as not mounted" ;;
*) assert_fail "mount-probe-missing" "[$(probe_state "$_work/absent")]" ;;
esac

# ── case precision: a string prefix of a mounted path is not itself mounted ──
case "$(probe_state "$_prefix_sibling")" in
absent:not-listed) assert_pass "a path that only prefixes a mounted path reads as not mounted" ;;
*) assert_fail "mount-probe-prefix" \
  "$_prefix_sibling matched the entry for $_prefix_sibling-sibling ([$(probe_state "$_prefix_sibling")])" ;;
esac

# ── a failed mount read is not evidence of absence ───────────────────────────
# `mount` here exits non-zero and prints nothing, which must not read as
# "nothing is mounted". The state function answers a third value, and that is
# the whole point of it: the callers that act on the answer start a mount on
# "not mounted", so a read that failed has to be distinguishable from a read
# that succeeded and found nothing.
cat >"$_shim_dir/mount" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$_shim_dir/mount"
case "$(probe_state "$_plain_dir")" in
unknown:mount-status-1) assert_pass "an unreadable mount table is not read as evidence of absence" ;;
*) assert_fail "mount-probe-unreadable" \
  "a failed mount read was not reported as undeterminable ([$(probe_state "$_plain_dir")])" ;;
esac

# The predicate keeps its two-valued contract on the same input, and the reason
# is named: it answers 0 so that no caller which acts on "not mounted" starts a
# mount on a volume that may already be attached. Asserted directly because the
# state function above only proves the backend, not the contract callers hold.
_contains_rc=0
_contains_out="$(svc_mount_table_contains "$_plain_dir" 2>&1)" || _contains_rc=$?
if [ "$_contains_rc" -eq 0 ]; then
  assert_pass "an unreadable mount table still reads as mounted to the predicate"
else
  assert_fail "mount-probe-unreadable-predicate" \
    "the predicate answered 'not mounted' (rc=$_contains_rc) for a table it could not read: $_contains_out"
fi
case "$_contains_out" in
*"mount exited 1"*) assert_pass "the predicate names the reader's status" ;;
*) assert_fail "mount-probe-unreadable-reason" "the predicate did not name the reader's status: $_contains_out" ;;
esac

# ── darwin: a query that could not run is not evidence of absence ────────────
# The macOS backend is sourced last, after every assertion above, because it
# redefines the backend_* names they read. diskutil is shimmed for the same
# reason the mount table is: the state under test is a diskutil that cannot run,
# which a healthy host cannot be relied on to produce. macos-fskit.sh is sourced
# with it and only defines functions, so this runs on a Linux host unchanged.
# shellcheck source=../../src/scripts/lib/mount-backend-darwin.sh
. "$SCRIPT_DIR/../../src/scripts/lib/mount-backend-darwin.sh"

cat >"$_shim_dir/diskutil" <<'SHIM'
#!/bin/sh
exit 7
SHIM
chmod +x "$_shim_dir/diskutil"

_darwin_full="$_work/darwin-full"
_darwin_empty="$_work/darwin-empty"
_darwin_unreadable="$_work/darwin-unreadable"
mkdir -p "$_darwin_full" "$_darwin_empty" "$_darwin_unreadable"
: >"$_darwin_full/an-entry"
chmod 000 "$_darwin_unreadable"

# ── a diskutil that cannot run must not disable the only other probe ─────────
# The directory is readable and non-empty, so the directory test has an answer.
# Returning from inside the diskutil branch leaves the function with none, and
# reports a mount it never looked at as not mounted.
_darwin_full_state="$(backend_probe_state "$_darwin_full")"
case "$_darwin_full_state" in
present) assert_pass "a diskutil that cannot run still leaves the darwin directory test able to answer" ;;
*) assert_fail "darwin-probe-shadowed-fallback" \
  "a readable non-empty mount point read as [$_darwin_full_state] once diskutil could not run" ;;
esac

# WHY the readability is asserted before the answer: the undeterminable case
# exists for a directory this process cannot read, so a runner that can read one
# has not exercised it, and a bare token assertion would report the host's
# privilege rather than the probe's behaviour.
if ls -A "$_darwin_unreadable" >/dev/null 2>&1; then
  assert_fail "darwin-unreadable-fixture" \
    "this process reads a mode-000 directory, so the undeterminable case cannot be exercised"
else
  assert_pass "the fixture is a directory this process cannot read"
fi

# ── a directory that could not be read is not an empty directory ─────────────
# Both list as empty; only ls's own exit status separates them, and a mounted
# volume this caller may not read must not be reported as absent.
_darwin_unreadable_state="$(backend_probe_state "$_darwin_unreadable")"
case "$_darwin_unreadable_state" in
unknown:*) assert_pass "a darwin mount point this process cannot read is not read as absent" ;;
*) assert_fail "darwin-probe-unreadable-is-unknown" \
  "an unreadable mount point read as [$_darwin_unreadable_state] (expected unknown:*)" ;;
esac

# ── the undeterminable answer is reserved for the unreadable case ────────────
# An empty directory this process CAN read is a directory the probe read, and it
# read it as empty. Without this the case above would also pass against a probe
# that answered unknown for everything it could not confirm.
_darwin_empty_state="$(backend_probe_state "$_darwin_empty")"
case "$_darwin_empty_state" in
absent:not-listed) assert_pass "an empty readable directory still reads as not mounted on darwin" ;;
*) assert_fail "darwin-probe-empty-is-absent" \
  "an empty readable mount point read as [$_darwin_empty_state] (expected absent:not-listed)" ;;
esac

_darwin_missing_state="$(backend_probe_state "$_work/darwin-absent")"
case "$_darwin_missing_state" in
absent:not-listed) assert_pass "a missing mount point reads as not mounted on darwin" ;;
*) assert_fail "darwin-probe-missing" \
  "a missing mount point read as [$_darwin_missing_state] (expected absent:not-listed)" ;;
esac

chmod 755 "$_darwin_unreadable"

finish_tests
