#!/usr/bin/env bash
# mount-backend-linux.sh — backend_probe answers about MOUNT STATE, never content.
#
# The regression this guards is D54: the probe used to require a non-empty
# directory, so a mounted-but-empty remote root (a freshly created cloud folder)
# read as "not mounted". The runner then never set live, exhausted its attempts,
# and left the service permanently blocked on a mount that had actually
# succeeded. The inverse error matters just as much: a NON-empty directory that
# is not a mount must not read as mounted, or the runner would skip a genuine
# revival. Both directions are asserted below, plus the case boundary (a mount
# point that is a string prefix of a mounted path is not itself mounted).
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

probe_rc() { # <path>
  if backend_probe "$1"; then printf '0'; else printf '1'; fi
}

# ── D54 regression: mounted but EMPTY must read as mounted ───────────────────
case "$(probe_rc "$_mounted_empty")" in
0) assert_pass "a mounted-but-empty mount point reads as mounted" ;;
*) assert_fail "mount-probe-empty-mounted" \
  "an empty mounted remote root read as NOT mounted (rc=$(probe_rc "$_mounted_empty")) — D54" ;;
esac

# ── mounted and non-empty stays mounted ──────────────────────────────────────
case "$(probe_rc "$_mounted_full")" in
0) assert_pass "a mounted-and-non-empty mount point reads as mounted" ;;
*) assert_fail "mount-probe-nonempty-mounted" "rc=$(probe_rc "$_mounted_full")" ;;
esac

# ── inverse error: a NON-empty directory that is not mounted is NOT mounted ──
case "$(probe_rc "$_plain_dir")" in
1) assert_pass "a non-empty directory that is not mounted reads as not mounted" ;;
*) assert_fail "mount-probe-nonempty-unmounted" \
  "a non-empty unmounted directory read as mounted (rc=$(probe_rc "$_plain_dir")) — revival would be skipped" ;;
esac

# ── a missing path is not mounted ────────────────────────────────────────────
case "$(probe_rc "$_work/absent")" in
1) assert_pass "a missing mount point reads as not mounted" ;;
*) assert_fail "mount-probe-missing" "rc=$(probe_rc "$_work/absent")" ;;
esac

# ── case precision: a string prefix of a mounted path is not itself mounted ──
case "$(probe_rc "$_prefix_sibling")" in
1) assert_pass "a path that only prefixes a mounted path reads as not mounted" ;;
*) assert_fail "mount-probe-prefix" \
  "$_prefix_sibling matched the entry for $_prefix_sibling-sibling (rc=$(probe_rc "$_prefix_sibling"))" ;;
esac

# ── a failed mount read is not evidence of absence ───────────────────────────
# `mount` here exits non-zero and prints nothing, which must not be read as
# "nothing is mounted": the callers act on "not mounted" by starting a mount on
# top of a volume that may be live.
cat >"$_shim_dir/mount" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$_shim_dir/mount"
case "$(probe_rc "$_plain_dir")" in
0) assert_pass "an unreadable mount table is not read as evidence of absence" ;;
*) assert_fail "mount-probe-unreadable" \
  "a failed mount read was treated as 'not mounted' (rc=$(probe_rc "$_plain_dir"))" ;;
esac

finish_tests
