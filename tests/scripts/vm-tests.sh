#!/usr/bin/env bash
# Tests for the POSIX VM library: vm_wait_until bounds every wait and warns on
# timeout, wait_for_utm_registration keeps its own probe, cadence, and timeout on
# top of it, and the guest-script writer renders in place, so an unchanged script
# keeps its inode and only stale managed scripts are pruned.
#
# Run with: bash tests/scripts/vm-tests.sh
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

ensure_safe_rm_env

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# WHY: the suite drives the product in-process, so the helper's warning text is
# asserted verbatim and color has to be off on the captured stderr.
export NO_COLOR=1
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

require_command jq "the guest-script desired set is read from the VM manifest with jq"
require_command cmp "vm_write_if_changed compares rendered bytes against the deployed script with cmp"
require_command find "temp-file leftovers are checked with find"

# WHY: these cases drive the writers directly, so only the globals they read are
# set; vm_init() would need a live manifest and host profile.
dry_run=false

_tmp="$(mktemp -d)"
_real_utmctl="$UTMCTL"
_real_rm="$(type -P rm)"
_real_mv="$(type -P mv)"
_rm_record="$_tmp/deletions.txt"

# shellcheck disable=SC2329 # reason: dispatched by name from the EXIT trap
_cleanup() {
  rm -rf "$_tmp"
}
trap '_cleanup' EXIT

# PATH recorder in front of the host's rm. A managed guest-script deletion is
# recorded and then really deleted, so a stale script has to leave the directory
# while the writer's own dot-prefixed temp-file cleanup stays out of the record.
_install_rm_recorder() {
  mkdir -p "$_tmp/bin"
  : >"$_rm_record"
  cat >"$_tmp/bin/rm" <<SHIM
#!/bin/sh
for _shim_arg in "\$@"; do
  case "\${_shim_arg#-}" in
  "\$_shim_arg") ;;
  *) continue ;;
  esac
  case "\${_shim_arg##*/}" in
  start-* | stop-* | pack.* | unpack.*) printf '%s\n' "\${_shim_arg##*/}" >>"$_rm_record" ;;
  esac
done
exec "$_real_rm" "\$@"
SHIM
  chmod 755 "$_tmp/bin/rm"
  PATH="$_tmp/bin:$PATH"
}
_install_rm_recorder

# mv shim in the same PATH directory. It fails only for the exact destination a
# case names, because the host's deletion route moves files to its trash with mv
# too: a shim that failed every rename would break the cleanup it is meant to
# test the absence of.
_install_mv_shim() {
  _imv_real="$1"
  cat >"$_tmp/bin/mv" <<SHIM
#!/bin/sh
_imv_last=''
for _imv_arg in "\$@"; do
  _imv_last="\$_imv_arg"
done
if [ -n "\${NUCLEUS_TEST_FAIL_MV_TARGET:-}" ] && [ "\$_imv_last" = "\$NUCLEUS_TEST_FAIL_MV_TARGET" ]; then
  echo "mv: simulated failure" >&2
  exit 1
fi
exec "$_imv_real" "\$@"
SHIM
  chmod 755 "$_tmp/bin/mv"
}
_install_mv_shim "$_real_mv"

# Octal permission bits and inode of FILE, split on the stat spelling so the
# assertions read the same on BSD and GNU hosts.
file_mode() { # <file>
  case "$(uname -s)" in
  Darwin) stat -f '%Lp' "$1" ;;
  *) stat -c '%a' "$1" ;;
  esac
}

file_inode() { # <file>
  case "$(uname -s)" in
  Darwin) stat -f '%i' "$1" ;;
  *) stat -c '%i' "$1" ;;
  esac
}

# Dot-prefixed buffers a write left behind in DIR, one per line. The writer keeps
# its buffer invisible to the managed-pattern prune, so a leftover here would be
# collected by nothing else.
temp_files() { # <dir>
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -name '.tmp.*' -print
}

# Minimal manifest for the prune cases: the desired set names both VMs, enabled or
# not, so every other managed name in the scripts directory is stale.
write_prune_manifest() { # <path>
  cat >"$1" <<'VMJSON'
{
  "VMs": [
    {
      "id": "keep",
      "type": "NixOS"
    },
    {
      "enabled": false,
      "hosts": [
        "NixOS"
      ],
      "id": "parked",
      "type": "NixOS"
    }
  ]
}
VMJSON
}

# WHY: the prune cases target the desired-set diff, not template rendering, so the
# writer renders the one desired file through the real vm_write_if_changed.
# _writer_stub_status lets a case make the write fail, which must abort the prune.
_writer_stub_status=0
# shellcheck disable=SC2329 # reason: invoked by name from vm_prune_and_write_all_guest_scripts in vm.sh
vm_write_all_guest_scripts() {
  if [ "$_writer_stub_status" -ne 0 ]; then
    return "$_writer_stub_status"
  fi
  printf 'desired\n' | vm_write_if_changed "$VM_DIR/scripts/start-keep.sh" 755
}

# Hermetic utmctl stub that runs BODY for every invocation, so the call-site
# cases need neither UTM nor a live hypervisor.
_write_fake_utmctl() {
  _wfut_body="$1"
  _wfut_path="$_tmp/utmctl"
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$_wfut_body"
  } >"$_wfut_path"
  chmod 755 "$_wfut_path"
  printf '%s\n' "$_wfut_path"
}

# A probe that never succeeds must return non-zero, and the timeout has to be
# the site's own: 1s here, never the helper inventing a bound.
test_wait_until_times_out() {
  local _start _elapsed _status=0 _err=''
  _start="$(date +%s)"
  _err="$(vm_wait_until "never to appear" 1 false 2>&1)" || _status=$?
  _elapsed=$(($(date +%s) - _start))
  if [ "$_status" -eq 0 ]; then
    assert_fail "wait_until times out" "returned 0 for a probe that never succeeds"
  elif [ "$_elapsed" -gt 3 ]; then
    assert_fail "wait_until times out" "waited ${_elapsed}s on a 1s timeout"
  elif ! printf '%s' "$_err" | grep -q 'timed out after 1s waiting for never to appear'; then
    assert_fail "wait_until times out" "no timeout warning naming the wait: $_err"
  else
    assert_pass "wait_until times out with a warning that names the wait"
  fi
}

test_wait_until_returns_on_success() {
  local _marker="$_tmp/waited.$$" _status=0
  : >"$_marker"
  vm_wait_until "marker" 5 test -f "$_marker" || _status=$?
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_until succeeds on the first probe"
  else
    assert_fail "wait_until returns on success" "returned $_status against an existing marker"
  fi
}

# A probe that starts succeeding only later separates "polls again" from
# "probes once and gives up".
test_wait_until_polls_until_success() {
  local _marker="$_tmp/late.$$" _status=0
  (
    sleep 1
    : >"$_marker"
  ) &
  vm_wait_until "late marker" 5 test -f "$_marker" || _status=$?
  wait
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_until polls until the probe succeeds"
  else
    assert_fail "wait_until polls until success" "returned $_status for a marker created 1s in"
  fi
}

# The call site keeps its own 15s default and its own utmctl probe; the timeout
# path is the only part that changed, from a silent return to a loud one.
test_wait_for_utm_registration_times_out() {
  local _start _elapsed _status=0 _err='' _fake
  _fake="$(_write_fake_utmctl 'echo "UUID Status Name"')"
  UTMCTL="$_fake"
  _start="$(date +%s)"
  _err="$(wait_for_utm_registration "absent-vm" 1 2>&1)" || _status=$?
  _elapsed=$(($(date +%s) - _start))
  UTMCTL="$_real_utmctl"
  if [ "$_status" -eq 0 ]; then
    assert_fail "wait_for_utm_registration times out" "returned 0 with no VM registered"
  elif [ "$_elapsed" -gt 3 ]; then
    assert_fail "wait_for_utm_registration times out" "waited ${_elapsed}s on a 1s timeout"
  elif ! printf '%s' "$_err" | grep -q "timed out after 1s waiting for UTM to register 'absent-vm'"; then
    assert_fail "wait_for_utm_registration times out" "no timeout warning naming the wait: $_err"
  else
    assert_pass "wait_for_utm_registration fails loudly through the shared helper"
  fi
}

# Success path through the real utmctl table parser: column 3 of a listing.
test_wait_for_utm_registration_detects_registered_vm() {
  local _status=0 _fake
  _fake="$(_write_fake_utmctl 'echo "UUID Status Name"
echo "0000 stopped registered-vm"')"
  UTMCTL="$_fake"
  wait_for_utm_registration "registered-vm" 5 || _status=$?
  UTMCTL="$_real_utmctl"
  if [ "$_status" -eq 0 ]; then
    assert_pass "wait_for_utm_registration returns once utmctl lists the VM"
  else
    assert_fail "wait_for_utm_registration detects a registration" "returned $_status for a listed VM"
  fi
}

# An unchanged render must not touch the file at all: a delete-and-recreate pass
# changes the inode and resets the mode, which is what the apply-time sync used to
# do to every generated script. The explicit chmod to 640 is what makes a
# rewritten file visible even when the content matches, and the managed name is
# what lets the PATH recorder catch a delete-and-recreate.
test_write_if_changed_leaves_unchanged_target() {
  local _target="$_tmp/start-unchanged.sh" _inode_before _inode_after _mode _content
  printf 'same\n' | vm_write_if_changed "$_target" 755
  chmod 640 "$_target"
  _inode_before="$(file_inode "$_target")"
  : >"$_rm_record"
  printf 'same\n' | vm_write_if_changed "$_target" 755
  _inode_after="$(file_inode "$_target")"
  _mode="$(file_mode "$_target")"
  _content="$(cat "$_target")"
  if [ "$_inode_before" != "$_inode_after" ]; then
    assert_fail "vm_write_if_changed leaves an unchanged target alone" "inode changed $_inode_before -> $_inode_after"
  elif [ "$_mode" != "640" ]; then
    assert_fail "vm_write_if_changed leaves an unchanged target alone" "mode changed to $_mode"
  elif [ "$_content" != "same" ]; then
    assert_fail "vm_write_if_changed leaves an unchanged target alone" "content is [$_content]"
  elif [ -s "$_rm_record" ]; then
    assert_fail "vm_write_if_changed leaves an unchanged target alone" "a managed deletion was recorded: $(cat "$_rm_record")"
  else
    assert_pass "vm_write_if_changed leaves an unchanged target alone"
  fi
}

# A changed render keeps the writer's mode even when the deployed file was left
# with another one, and it replaces the file by rename rather than by deleting it
# first, so the recorder sees no managed deletion for our own output.
test_write_if_changed_replaces_changed_target() {
  local _target="$_tmp/start-changed.sh" _mode _content _temp_left
  printf 'old\n' | vm_write_if_changed "$_target" 755
  chmod 600 "$_target"
  : >"$_rm_record"
  printf 'new\n' | vm_write_if_changed "$_target" 755
  _mode="$(file_mode "$_target")"
  _content="$(cat "$_target")"
  _temp_left="$(temp_files "$_tmp")"
  if [ "$_content" != "new" ]; then
    assert_fail "vm_write_if_changed replaces changed content" "content is [$_content]"
  elif [ "$_mode" != "755" ]; then
    assert_fail "vm_write_if_changed replaces changed content" "mode is $_mode, expected the writer's 755"
  elif [ -s "$_rm_record" ]; then
    assert_fail "vm_write_if_changed replaces changed content" "a managed deletion was recorded: $(cat "$_rm_record")"
  elif [ -n "$_temp_left" ]; then
    assert_fail "vm_write_if_changed replaces changed content" "temp files left behind: $_temp_left"
  else
    assert_pass "vm_write_if_changed replaces changed content and its mode"
  fi
}

# A directory target has to fail before the buffer exists: mv into a directory
# succeeds by moving the temp file inside it, which would leave no script at all
# and a stray buffer nothing prunes.
test_write_if_changed_rejects_directory_target() {
  local _parent="$_tmp/target-dir" _target _status=0 _err _temp_left
  mkdir -p "$_parent"
  _target="$_parent/scripts"
  mkdir -p "$_target"
  _err="$(printf 'content\n' | vm_write_if_changed "$_target" 755 2>&1)" || _status=$?
  _temp_left="$(temp_files "$_parent")"
  if [ "$_status" -eq 0 ]; then
    assert_fail "vm_write_if_changed rejects a directory target" "returned 0 for a directory target"
  elif ! printf '%s' "$_err" | grep -q 'guest script path is a directory'; then
    assert_fail "vm_write_if_changed rejects a directory target" "no error naming the directory target: $_err"
  elif [ ! -d "$_target" ]; then
    assert_fail "vm_write_if_changed rejects a directory target" "the target is no longer a directory"
  elif [ -n "$_temp_left" ]; then
    assert_fail "vm_write_if_changed rejects a directory target" "temp files left behind: $_temp_left"
  else
    assert_pass "vm_write_if_changed rejects a directory target before buffering"
  fi
}

# A failed rename has to clean up the buffer and name the target: the buffer is
# dot-prefixed, so the prune can never collect it, and the target must keep the
# deployed bytes rather than end up half-replaced.
test_write_if_changed_reports_failed_replace() {
  local _dir="$_tmp/replace-fail" _target _status=0 _err _content _temp_left
  mkdir -p "$_dir"
  _target="$_dir/start-failed.sh"
  printf 'old\n' | vm_write_if_changed "$_target" 755
  export NUCLEUS_TEST_FAIL_MV_TARGET="$_target"
  _err="$(printf 'new\n' | vm_write_if_changed "$_target" 755 2>&1)" || _status=$?
  unset NUCLEUS_TEST_FAIL_MV_TARGET
  _content="$(cat "$_target")"
  _temp_left="$(temp_files "$_dir")"
  if [ "$_status" -eq 0 ]; then
    assert_fail "vm_write_if_changed reports a failed replace" "returned 0 when the rename failed"
  elif ! printf '%s' "$_err" | grep -q 'failed to replace'; then
    assert_fail "vm_write_if_changed reports a failed replace" "no error naming the failed replace: $_err"
  elif [ "$_content" != "old" ]; then
    assert_fail "vm_write_if_changed reports a failed replace" "the target content is [$_content]"
  elif [ -n "$_temp_left" ]; then
    assert_fail "vm_write_if_changed reports a failed replace" "temp files left behind: $_temp_left"
  else
    assert_pass "vm_write_if_changed reports a failed replace and leaves the target alone"
  fi
}

# Write-then-prune: the desired script survives untouched, the stale managed one
# goes, and a custom file in scripts/ is never the library's business.
test_prune_removes_only_stale_managed_scripts() {
  local _dir="$_tmp/prune" _keep _stale _custom _inode_before _inode_after _mode _content _record _temp_left
  mkdir -p "$_dir/scripts"
  write_prune_manifest "$_dir/VMs.json"
  _keep="$_dir/scripts/start-keep.sh"
  _stale="$_dir/scripts/start-old.sh"
  _custom="$_dir/scripts/notes.txt"
  printf 'desired\n' | vm_write_if_changed "$_keep" 755
  printf 'stale\n' >"$_stale"
  chmod 755 "$_stale"
  printf 'notes\n' >"$_custom"
  _inode_before="$(file_inode "$_keep")"
  : >"$_rm_record"
  VM_DIR="$_dir"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  MANIFEST="$_dir/VMs.json"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  dry_run=false
  vm_prune_and_write_all_guest_scripts >"$_dir/out.log" 2>&1
  _inode_after="$(file_inode "$_keep")"
  _mode="$(file_mode "$_keep")"
  _content="$(cat "$_keep")"
  _record="$(cat "$_rm_record")"
  _temp_left="$(temp_files "$_dir/scripts")"
  if [ -e "$_stale" ]; then
    assert_fail "prune removes a stale managed script" "start-old.sh still present"
  elif [ ! -f "$_custom" ] || [ "$(cat "$_custom")" != "notes" ]; then
    assert_fail "prune removes a stale managed script" "the custom notes.txt was touched"
  elif [ "$_inode_before" != "$_inode_after" ] || [ "$_mode" != "755" ] || [ "$_content" != "desired" ]; then
    assert_fail "prune removes a stale managed script" "the desired script changed: inode $_inode_before -> $_inode_after, mode $_mode, content [$_content]"
  elif [ "$_record" != "start-old.sh" ]; then
    assert_fail "prune removes a stale managed script" "the recorded deletions are [$_record]"
  elif [ -n "$_temp_left" ]; then
    assert_fail "prune removes a stale managed script" "temp files left behind: $_temp_left"
  else
    assert_pass "prune removes only the stale managed script and writes the desired one in place"
  fi
}

# A failed write must abort before the prune: the stale script survives, nothing
# is recorded as deleted, and the caller sees a non-zero status.
test_prune_skips_when_writer_fails() {
  local _dir="$_tmp/prune-fail" _keep _stale _status=0 _record
  mkdir -p "$_dir/scripts"
  write_prune_manifest "$_dir/VMs.json"
  _keep="$_dir/scripts/start-keep.sh"
  _stale="$_dir/scripts/start-old.sh"
  printf 'deployed\n' | vm_write_if_changed "$_keep" 755
  printf 'stale\n' >"$_stale"
  : >"$_rm_record"
  VM_DIR="$_dir"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  MANIFEST="$_dir/VMs.json"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  dry_run=false
  _writer_stub_status=1
  vm_prune_and_write_all_guest_scripts >"$_dir/out.log" 2>&1 || _status=$?
  _writer_stub_status=0
  _record="$(cat "$_rm_record")"
  if [ "$_status" -eq 0 ]; then
    assert_fail "prune skips after a failed write" "returned 0 for a failed writer"
  elif [ ! -f "$_stale" ]; then
    assert_fail "prune skips after a failed write" "start-old.sh was pruned after the write failed"
  elif [ "$(cat "$_keep")" != "deployed" ]; then
    assert_fail "prune skips after a failed write" "the desired script changed: $(cat "$_keep")"
  elif [ -n "$_record" ]; then
    assert_fail "prune skips after a failed write" "a deletion was recorded: $_record"
  else
    assert_pass "prune leaves the tree alone and returns non-zero when a write fails"
  fi
}

# The desired set covers every manifest VM, so a disabled one keeps its rendered
# script instead of being pruned as stale.
test_prune_keeps_disabled_vm_script() {
  local _dir="$_tmp/prune-disabled" _parked _inode_before _inode_after _content _record
  mkdir -p "$_dir/scripts"
  write_prune_manifest "$_dir/VMs.json"
  _parked="$_dir/scripts/start-parked.sh"
  printf 'parked\n' >"$_parked"
  chmod 755 "$_parked"
  _inode_before="$(file_inode "$_parked")"
  : >"$_rm_record"
  VM_DIR="$_dir"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  MANIFEST="$_dir/VMs.json"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  dry_run=false
  vm_prune_and_write_all_guest_scripts >"$_dir/out.log" 2>&1
  # WHY: the pruned case must fail the assertion, not abort the suite under set -e,
  # so a missing script is reported as 'missing' instead of being stat'ed.
  _inode_after='missing'
  _content=''
  if [ -f "$_parked" ]; then
    _inode_after="$(file_inode "$_parked")"
    _content="$(cat "$_parked")"
  fi
  _record="$(cat "$_rm_record")"
  if [ ! -f "$_parked" ] || [ "$_inode_before" != "$_inode_after" ] || [ "$_content" != "parked" ]; then
    assert_fail "prune keeps a disabled VM's script" "start-parked.sh is gone or changed: inode $_inode_before -> $_inode_after, content [$_content], recorded [$_record]"
  elif [ -n "$_record" ]; then
    assert_fail "prune keeps a disabled VM's script" "a deletion was recorded: $_record"
  else
    assert_pass "prune keeps a disabled VM's desired script"
  fi
}

# A preview has to be read-only: the deployed script keeps its bytes even though
# the render differs, the stale file stays, and nothing reaches the deleter.
test_prune_dry_run_reports_without_writing_or_deleting() {
  local _dir="$_tmp/prune-dry" _keep _stale _custom _inode_before _inode_after _mode _content _record _temp_left
  mkdir -p "$_dir/scripts"
  write_prune_manifest "$_dir/VMs.json"
  _keep="$_dir/scripts/start-keep.sh"
  _stale="$_dir/scripts/start-old.sh"
  _custom="$_dir/scripts/notes.txt"
  printf 'deployed\n' | vm_write_if_changed "$_keep" 755
  chmod 640 "$_keep"
  printf 'stale\n' >"$_stale"
  printf 'notes\n' >"$_custom"
  _inode_before="$(file_inode "$_keep")"
  : >"$_rm_record"
  VM_DIR="$_dir"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  MANIFEST="$_dir/VMs.json"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  dry_run=true
  vm_prune_and_write_all_guest_scripts >"$_dir/out.log" 2>&1
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_prune_and_write_all_guest_scripts
  dry_run=false
  _inode_after="$(file_inode "$_keep")"
  _mode="$(file_mode "$_keep")"
  _content="$(cat "$_keep")"
  _record="$(cat "$_rm_record")"
  _temp_left="$(temp_files "$_dir/scripts")"
  if [ "$_inode_before" != "$_inode_after" ] || [ "$_mode" != "640" ] || [ "$_content" != "deployed" ]; then
    assert_fail "prune dry-run writes nothing" "the deployed script changed: inode $_inode_before -> $_inode_after, mode $_mode, content [$_content]"
  elif [ ! -f "$_stale" ]; then
    assert_fail "prune dry-run writes nothing" "start-old.sh was deleted in a preview"
  elif [ -n "$_record" ]; then
    assert_fail "prune dry-run writes nothing" "a deletion was recorded: $_record"
  elif ! grep -q 'update guest script' "$_dir/out.log"; then
    assert_fail "prune dry-run writes nothing" "the preview does not name the would-be update: $(cat "$_dir/out.log")"
  elif ! grep -q 'remove stale guest script' "$_dir/out.log"; then
    assert_fail "prune dry-run writes nothing" "the preview does not name the stale script: $(cat "$_dir/out.log")"
  elif [ -n "$_temp_left" ]; then
    assert_fail "prune dry-run writes nothing" "temp files left behind: $_temp_left"
  else
    assert_pass "prune dry-run reports the pending update and prune without touching the tree"
  fi
}

# The pack/unpack wrappers are written through the same helper, so a second sync
# leaves them alone instead of replacing four files that already match.
test_pack_unpack_writers_update_in_place() {
  local _dir="$_tmp/wrappers" _inode_before _inode_after _mode _exec_line _temp_left
  mkdir -p "$_dir"
  VM_DIR="$_dir"
  # shellcheck disable=SC2034 # reason: read at runtime by the sourced vm_write_pack_unpack_scripts
  dry_run=false
  vm_write_pack_unpack_scripts >"$_dir/out.log" 2>&1
  _inode_before="$(file_inode "$_dir/scripts/pack.sh")"
  _mode="$(file_mode "$_dir/scripts/pack.sh")"
  _exec_line="$(sed -n '$p' "$_dir/scripts/pack.sh")"
  : >"$_rm_record"
  vm_write_pack_unpack_scripts >>"$_dir/out.log" 2>&1
  _inode_after="$(file_inode "$_dir/scripts/pack.sh")"
  _temp_left="$(temp_files "$_dir/scripts")"
  if [ "$_mode" != "755" ] || [ "$_exec_line" != 'exec nucleus-vm pack "$@"' ]; then
    assert_fail "pack/unpack writers render through vm_write_if_changed" "mode $_mode, last line [$_exec_line]"
  elif [ "$_inode_before" != "$_inode_after" ]; then
    assert_fail "pack/unpack writers render through vm_write_if_changed" "inode changed $_inode_before -> $_inode_after on an unchanged wrapper"
  elif [ -s "$_rm_record" ]; then
    assert_fail "pack/unpack writers render through vm_write_if_changed" "a managed deletion was recorded: $(cat "$_rm_record")"
  elif [ -n "$_temp_left" ]; then
    assert_fail "pack/unpack writers render through vm_write_if_changed" "temp files left behind: $_temp_left"
  else
    assert_pass "pack/unpack writers render through vm_write_if_changed and leave a matching wrapper alone"
  fi
}

test_wait_until_times_out
test_wait_until_returns_on_success
test_wait_until_polls_until_success
test_wait_for_utm_registration_times_out
test_wait_for_utm_registration_detects_registered_vm
test_write_if_changed_leaves_unchanged_target
test_write_if_changed_replaces_changed_target
test_write_if_changed_rejects_directory_target
test_write_if_changed_reports_failed_replace
test_prune_removes_only_stale_managed_scripts
test_prune_skips_when_writer_fails
test_prune_keeps_disabled_vm_script
test_prune_dry_run_reports_without_writing_or_deleting
test_pack_unpack_writers_update_in_place

finish_tests
