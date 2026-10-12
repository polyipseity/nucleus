#!/usr/bin/env bash
# mount-backend-prepare-tests.sh: the capability gate in backend_prepare.
#
# backend_prepare blocks a mount before it is attempted when the rclone on PATH
# cannot run the backend subcommand, writing a blocked record and returning 20
# so the runner notices without retrying. The gate has two failure shapes and
# they share one block: an rclone whose `nfsmount --help` fails, which is what
# an rclone build without nfsmount answers. The assertions read the health
# record as well as the return code: a gate that returns 20 without recording
# leaves the runner blind to why the mount never started.
#
# WHY the probe is `nfsmount --help` and not `help nfsmount`: rclone's `help`
# command exits 0 for any topic, including ones that do not exist, so it cannot
# separate a build with nfsmount from one without it. The subcommand's own
# --help fails when the subcommand is missing.
#
# WHY the probe is stubbed: the gate asks the rclone binary on PATH a question,
# and a suite must exercise both answers without swapping the host's rclone.
# backend_prepare is the real function; the stub only supplies the one input
# the test machine cannot provide offline.
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

require_command jq "the health-record assertions read the record with jq"

unset _NUCLEUS_MOUNT_BACKEND_DARWIN_SOURCED
# shellcheck source=../../src/scripts/lib/mount-backend-darwin.sh
. "$REPO_ROOT/src/scripts/lib/mount-backend-darwin.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin"
export PATH="$_tmp/bin:$PATH"

# The stub answers `nfsmount --help` with FAKE_NFSMOUNT_RC, modelling an rclone
# whose subcommand exists (0) or is missing (non-zero). Any other invocation
# exits 0 so an unexpected probe shape is visible as a pass rather than hidden
# as a failure.
cat >"$_tmp/bin/rclone" <<'FAKE_RCLONE'
#!/usr/bin/env bash
if [ "${1:-}" = "nfsmount" ] && [ "${2:-}" = "--help" ]; then
  exit "${FAKE_NFSMOUNT_RC:-0}"
fi
exit 0
FAKE_RCLONE
chmod +x "$_tmp/bin/rclone"

readonly INSTANCE="test-instance"

assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

assert_mentions() { # <test name> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1" ;;
  *) assert_fail "$1" "output did not mention '$3': $2" ;;
  esac
}

record_field() { # <field>
  svc_health_get "$INSTANCE" "$1"
}

# prepare_with runs the real backend_prepare against the stub and prints its
# return code. The env travels with the subshell, so each case controls the
# probe answer exactly.
prepare_with() { # <nfsmount rc>
  local nfsmount_rc="$1" rc=0
  (
    export FAKE_NFSMOUNT_RC="$nfsmount_rc"
    backend_prepare "$INSTANCE"
  ) || rc=$?
  printf '%s\n' "$rc"
}

section "1" "the nfsmount capability gate"

rc="$(prepare_with 0)"
assert_eq "an rclone with nfsmount passes the gate" "0" "$rc"
# A passing gate writes nothing: svc_health_get on the absent record reads as
# the empty string, and that emptiness is the assertion (a blocked record here
# would stop the runner before it ever mounts).
assert_eq "a passing gate writes no blocked record" \
  "" "$(record_field state)"

rc="$(prepare_with 1)"
assert_eq "an rclone without nfsmount returns 20" "20" "$rc"
assert_eq "the blocked record is written" "blocked" "$(record_field state)"
assert_eq "the blocked record carries mount-backend-unsupported" \
  "mount-backend-unsupported" "$(record_field class)"
assert_mentions "the remedy names nfsmount" \
  "$(record_field remedy)" "nfsmount"
assert_mentions "the remedy names rclone" \
  "$(record_field remedy)" "rclone"

section "2" "the blocked class is terminal"

# A capability the host cannot gain by retrying must block, not loop: the
# default in backend_is_transient is terminal, and only the listed classes
# retry.
if backend_is_transient "mount-backend-unsupported"; then
  assert_fail "mount-backend-unsupported-is-terminal" \
    "backend_is_transient returned 0: an unsupported backend would be retried forever"
else
  assert_pass "mount-backend-unsupported is terminal"
fi

finish_tests
