#!/usr/bin/env bash
# mount-backend-linux.sh — backend_probe_state answers about MOUNT STATE, never
# content, and keeps the undeterminable answer.
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

finish_tests
