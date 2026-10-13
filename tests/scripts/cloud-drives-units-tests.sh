#!/usr/bin/env bash
# cloud-drives-units-tests.sh: contract of the generated NixOS mount units.
#
# The units delegate every per-mount value to the positional wrapper CLI and
# delegate revival to systemd Restart=always, mirroring launchd KeepAlive on
# macOS. Two halves: static pins on the source, because rendering the units
# needs nixpkgs, which is unreachable offline here, and a behavioural run of
# the real wrapper against a space-containing mount point, which is the
# argv-whole guarantee the old extracted-body tests existed for, now proven
# against shipped code instead of a generated string.
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
NIX_FILE="$REPO_ROOT/src/modules/cloud-drives.nix"
WRAPPER="$REPO_ROOT/src/scripts/services/rclone-mount.sh"

section "1" "the mount unit supervises instead of delegating retry"

# The Service block of the cloud-mount unit: everything after its Description
# line up to the closing brace. The block contains no nested braces, so the
# first closing brace terminates it.
SERVICE_BLOCK="$(
  awk '
    /Description = "rclone cloud mount:/ { in_mount = 1 }
    in_mount && /Service = \{/ { in_service = 1 }
    in_service { print }
    in_service && /^ +};[[:space:]]*$/ { exit }
  ' "$NIX_FILE"
)"
if [ -n "$SERVICE_BLOCK" ]; then
  assert_pass "cloud-mount Service block extracted"
else
  assert_fail "cloud-mount Service block extracted" "no cloud-mount unit found in cloud-drives.nix"
fi

if printf '%s' "$SERVICE_BLOCK" | grep -q 'Restart = "always"'; then
  assert_pass "systemd owns revival with Restart=always"
else
  assert_fail "systemd owns revival with Restart=always" "no Restart = \"always\" in the unit"
fi

if printf '%s' "$SERVICE_BLOCK" | grep -q 'RestartSec = 30'; then
  assert_pass "restart backoff is 30 seconds"
else
  assert_fail "restart backoff is 30 seconds" "no RestartSec = 30 in the unit"
fi

if printf '%s' "$SERVICE_BLOCK" | grep -q 'ExecStartPre = .* clean .*escapeShellArg'; then
  assert_pass "ExecStartPre runs the wrapper clean pass on the escaped mount point"
else
  assert_fail "ExecStartPre runs the wrapper clean pass on the escaped mount point" "no clean-mode ExecStartPre found"
fi

if printf '%s' "$SERVICE_BLOCK" | grep -q 'ExecStart = .*escapeShellArgs (mkMountCliArgs mount)'; then
  assert_pass "ExecStart carries the shared positional CLI with escaped words"
else
  assert_fail "ExecStart carries the shared positional CLI with escaped words" "ExecStart does not use escapeShellArgs over mkMountCliArgs"
fi

# Regression pin (Task 5 caught the POSIX rewrite silently dropping these):
# the base five rclone flags the pre-rewrite backends and the Windows catalog
# all inject must reach every mount on this host too.
if grep -q '++ baseMountArgs' "$NIX_FILE"; then
  assert_pass "mkMountCliArgs includes the base flag set"
else
  assert_fail "mkMountCliArgs includes the base flag set" "no ++ baseMountArgs in cloud-drives.nix"
fi

if grep -q -- '--vfs-cache-mode' "$NIX_FILE" && grep -q -- '--poll-interval' "$NIX_FILE" && grep -q -- '"NOTICE"' "$NIX_FILE"; then
  assert_pass "base flag set carries cache mode, poll interval, and NOTICE log level"
else
  assert_fail "base flag set carries cache mode, poll interval, and NOTICE log level" "one of the base five flags is missing from cloud-drives.nix"
fi

section "2" "deleted machinery stays deleted"

offenders="$(grep -n 'ExecStop' "$NIX_FILE" || true)"
if [ -z "$offenders" ]; then
  assert_pass "no ExecStop remains in cloud-drives.nix"
else
  assert_fail "no ExecStop remains in cloud-drives.nix" "$offenders"
fi

offenders="$(grep -n 'fusermount\|mkFusermountUnmount\|mkEnsureMountPoint' "$NIX_FILE" || true)"
if [ -z "$offenders" ]; then
  assert_pass "no fusermount unmount or mkdir helper remains"
else
  assert_fail "no fusermount unmount or mkdir helper remains" "$offenders"
fi

offenders="$(grep -n 'watchdog owns' "$NIX_FILE" || true)"
if [ -z "$offenders" ]; then
  assert_pass "no comment still hands revival to the watchdog"
else
  assert_fail "no comment still hands revival to the watchdog" "$offenders"
fi

# Banned-pattern check (permitted form per the testing guidelines): no unit
# command may nest a command inside `sh -c '…'`, which is the construction
# that let lib.escapeShellArg's quotes be consumed by an outer parse.
# Comment lines are skipped, otherwise the WHY comments that DESCRIBE the
# defect would register as occurrences OF it.
offenders="$(awk -v pat="sh -c '" '$0 ~ pat && $0 !~ /^[[:space:]]*#/ { print NR ": " $0 }' "$NIX_FILE")"
if [ -z "$offenders" ]; then
  assert_pass "no sh -c quoting in generated unit commands"
else
  assert_fail "no sh -c quoting in generated unit commands" "$offenders"
fi

# The user-space backend option must stay behind the darwin guard: fuse3 has
# no backend=fskit, so the binding has to remain an isDarwin optional.
if grep -q 'fskitBackendArgs = lib.optionals isDarwin' "$NIX_FILE"; then
  assert_pass "the fskit backend option stays darwin-guarded"
else
  assert_fail "the fskit backend option stays darwin-guarded" "fskitBackendArgs is no longer an isDarwin optional"
fi

section "3" "the wrapper clean pass keeps a space-containing mount point whole"

WORK="$(mktemp -d)"
SHIM="$WORK/shim"
mkdir -p "$SHIM"
trap 'rm -rf "$WORK"' EXIT

# make_shim NAME: install a recorder that logs its argv to its own per-name
# file, so each assertion discriminates on one program's behaviour.
make_shim() {
  local name="$1"
  cat >"$SHIM/$name" <<SHIM_BODY
#!/bin/sh
{
  printf 'argc=%d\n' "\$#"
  for _a in "\$@"; do
    printf 'arg=<%s>\n' "\$_a"
  done
} >>"$WORK/$name.rec"
SHIM_BODY
  chmod +x "$SHIM/$name"
}

MOUNT_POINT="/Users/a b/clouds/iCloud"

# The mount-table probe prints nothing, so the clean pass must skip the
# unmount and hand the whole path to rmdir and mkdir as ONE argument each.
make_shim mount
make_shim umount
make_shim rmdir
make_shim mkdir
make_shim rclone

PATH="$SHIM:$PATH" bash "$WRAPPER" clean "$MOUNT_POINT"

if grep -qxF "arg=<$MOUNT_POINT>" "$WORK/mkdir.rec" 2>/dev/null &&
  grep -qxF "arg=<$MOUNT_POINT>" "$WORK/rmdir.rec" 2>/dev/null; then
  assert_pass "clean passes the space-containing path as one argument"
else
  assert_fail "clean passes the space-containing path as one argument" "mkdir saw: $(tr '\n' ' ' <"$WORK/mkdir.rec" 2>/dev/null) rmdir saw: $(tr '\n' ' ' <"$WORK/rmdir.rec" 2>/dev/null)"
fi

if [ -s "$WORK/umount.rec" ]; then
  assert_fail "clean skips the unmount when the mount table shows nothing" "$(tr '\n' ' ' <"$WORK/umount.rec")"
else
  assert_pass "clean skips the unmount when the mount table shows nothing"
fi

if [ -s "$WORK/rclone.rec" ]; then
  assert_fail "clean never invokes rclone" "$(tr '\n' ' ' <"$WORK/rclone.rec")"
else
  assert_pass "clean never invokes rclone"
fi

finish_tests
