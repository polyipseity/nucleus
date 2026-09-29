#!/usr/bin/env bash
# mount-backend-interface-tests.sh — the real backends define every name the
# runner calls.
#
# rclone-mount-tests.sh checks the same eight inside install_mocks, which defines
# them itself — which is how backend_probe could be dropped from the Linux
# backend and leave that check green. This suite mocks nothing: it asks only
# whether the name exists, not what it does.
#
# The eight are the backend_* calls in src/scripts/services/rclone-mount.sh,
# which also reads the _backend_capture and _backend_rclone_pid variables that
# this suite leaves unchecked. A ninth call added there needs adding here; this
# suite does not read the runner.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

_INTERFACE_NAMES=(
  backend_prepare
  backend_args
  backend_mount
  backend_probe_state
  backend_class
  backend_is_transient
  backend_unmount
  backend_remedy
)

# WHY backend_probe is absent. The runner does not call it and neither backend
# defines it: darwin's diskutil query is inline in backend_probe_state. The two
# backends are not required to have identical surfaces, so a name one of them
# happens to have is not a name to add to the other.

# WHY a subshell per backend, and never two backends in one shell. They define
# the same names, so a second source answers for the first and a backend that
# never sourced would be reported complete.
_defined_by() { # <backend file> <name>... — the names the backend defines
  local _file="$1"
  shift
  (
    # WHY the guarded source and the trailing success: unguarded, a failed
    # source ends this subshell, and a loop ending on a failed test returns
    # that failure. Either ends the caller's assignment before the eight run.
    # shellcheck source=/dev/null # reason: backend path is a runtime parameter
    if . "$_file"; then
      local _name
      for _name in "$@"; do
        declare -f "$_name" >/dev/null 2>&1 && printf '%s\n' "$_name"
      done
      return 0
    fi
  )
}

# WHY the canary tests sourcing, not a name. A name-based probe reports a
# sourcing failure as a missing interface the day that name is deleted as dead
# code; what a backend owes is a clean source and functions, not any one name.
_sourced_by() { # <backend file> — 0 when it sources and adds a function
  local _file="$1"
  (
    local _before _after
    _before="$(declare -F | wc -l)"
    # shellcheck source=/dev/null # reason: backend path is a runtime parameter
    . "$_file" || return 1
    _after="$(declare -F | wc -l)"
    [ "$_after" -gt "$_before" ]
  )
}

_check_backend() { # <platform> <backend file>
  local _platform="$1" _file="$2" _name _defined

  if _sourced_by "$_file"; then
    assert_pass "$_platform backend sourced and defined functions"
  else
    assert_fail "$_platform-backend-not-sourced" \
      "sourcing $_file failed or it defined no function, so every name below is reported missing for a reason that is not a missing interface"
  fi

  _defined="$(_defined_by "$_file" "${_INTERFACE_NAMES[@]}")"
  for _name in "${_INTERFACE_NAMES[@]}"; do
    if printf '%s\n' "$_defined" | grep -qxF "$_name"; then
      assert_pass "$_platform defines $_name"
    else
      assert_fail "$_platform-missing-$_name" \
        "rclone-mount.sh calls $_name and the $_platform backend does not define it"
    fi
  done
}

_check_backend linux "$SCRIPT_DIR/../../src/scripts/lib/mount-backend-linux.sh"
_check_backend darwin "$SCRIPT_DIR/../../src/scripts/lib/mount-backend-darwin.sh"

finish_tests
