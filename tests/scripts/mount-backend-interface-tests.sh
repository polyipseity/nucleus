#!/usr/bin/env bash
# mount-backend-interface-tests.sh — the real backends define every name the
# runner calls.
#
# rclone-mount-tests.sh checks the same eight inside install_mocks, which defines
# them itself — which is why 73318ae2 could drop backend_probe from the Linux
# backend and leave that check green. This suite mocks nothing: it asks only
# whether the name exists, not what it does.
#
# The eight are the backend_* calls in src/scripts/services/rclone-mount.sh.
# A ninth call added there needs adding here; this suite does not read the runner.
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
    # shellcheck source=/dev/null # reason: backend path is a runtime parameter
    . "$_file"
    local _name
    for _name in "$@"; do
      if declare -f "$_name" >/dev/null 2>&1; then
        printf '%s\n' "$_name"
      fi
    done
  )
}

_check_backend() { # <platform> <backend file>
  local _platform="$1" _file="$2" _name _defined

  # WHY backend_repair, which the runner never calls. Every assertion below
  # reports a name missing when the subshell sourced nothing, so an empty result
  # would otherwise read as a backend that defines nothing at all.
  if [ -n "$(_defined_by "$_file" backend_repair)" ]; then
    assert_pass "$_platform backend sourced, backend_repair defined"
  else
    assert_fail "$_platform-backend-not-sourced" \
      "sourcing $_file defined no function, so every name below is reported missing for a reason that is not a missing interface"
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
