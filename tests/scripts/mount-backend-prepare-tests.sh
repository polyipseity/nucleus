#!/usr/bin/env bash
# mount-backend-prepare-tests.sh: the macFUSE version gate in backend_prepare.
#
# backend_prepare blocks a mount before it is attempted when the installed
# macFUSE predates 5.4.0, the first release with the FSKit volume-operation
# interface. The gate has three probe outcomes and each one must write a
# provider-version block record and return 20, so the assertions read the health
# record as well as the return code: a gate that returns 20 without recording
# leaves the runner retrying a mount that can never succeed.
#
# WHY the probes are stubbed: the macFUSE CLI and its Info.plist live under
# /Library and /opt/homebrew, and a suite must exercise the gate without them.
# backend_prepare and its helpers are the real functions; the stubs only supply
# the inputs the test machine cannot provide offline.
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
mkdir -p "$_tmp/bin" "$_tmp/versions"
export PATH="$_tmp/bin:$PATH"

# Version fixtures: the fake plutil prints one of these as the plist's
# CFBundleShortVersionString.
printf '5.4.0\n' >"$_tmp/versions/5.4.0"
printf '5.3.3\n' >"$_tmp/versions/5.3.3"
printf 'garbage\n' >"$_tmp/versions/garbage"

_fixture_plist="$_tmp/macfuse-Info.plist"
printf '<plist/>\n' >"$_fixture_plist"
_absent_plist="$_tmp/absent-Info.plist"

export FAKE_PLUTIL_STATUS=0 FAKE_PLUTIL_VERSION_FILE

# WHY the argument shape: the gate reads the version with
# `plutil -extract CFBundleShortVersionString raw <path>`, and a stub answering
# a different shape would pin the wrong contract. The version comes from a
# fixture file so each case controls the probe output exactly.
cat >"$_tmp/bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
if [ "${1:-}" = "-extract" ] && [ "${2:-}" = "CFBundleShortVersionString" ] &&
  [ "${3:-}" = "raw" ] && [ -n "${4:-}" ]; then
  if [ "${FAKE_PLUTIL_STATUS:-0}" -ne 0 ]; then
    exit "${FAKE_PLUTIL_STATUS}"
  fi
  cat "$FAKE_PLUTIL_VERSION_FILE"
  exit 0
fi
exit 1
FAKE_PLUTIL
chmod +x "$_tmp/bin/plutil"

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

# prepare_with runs the real backend_prepare against fixtures and prints its
# return code. The macFUSE CLI probe and the FSKit module state are overridden
# inside the subshell only, so the parent keeps the real helpers for the path
# pin below. The stubbed module state answers `enabled`, which makes the real
# fskit_extension_is_enabled skip the re-registration branch, so no case can
# reach brew.
prepare_with() { # <plist> <cli present|absent> <plutil status> <version fixture>
  # WHY the stub_* names: backend_prepare declares its own `plist` and friends,
  # and its unset locals shadow same-named variables the stubs would read.
  local stub_plist="$1" stub_cli="$2" plutil_status="$3" version_file="$4" rc=0
  (
    macfuse_cli_bin() {
      if [ "$stub_cli" = "present" ]; then
        printf '%s\n' "$_tmp/bin/stub-macfuse"
      else
        return 1
      fi
    }
    macfuse_info_plist() { printf '%s\n' "$stub_plist"; }
    fskit_macfuse_module_state() { printf 'enabled\n'; }
    export FAKE_PLUTIL_STATUS="$plutil_status" FAKE_PLUTIL_VERSION_FILE="$version_file"
    backend_prepare "$INSTANCE"
  ) || rc=$?
  printf '%s\n' "$rc"
}

section "1" "the macFUSE version gate blocks and records"

rc="$(prepare_with "$_fixture_plist" present 0 "$_tmp/versions/5.4.0")"
assert_eq "a 5.4.0 install passes the gate" "0" "$rc"

rc="$(prepare_with "$_fixture_plist" present 0 "$_tmp/versions/5.3.3")"
assert_eq "an old install returns 20" "20" "$rc"
assert_eq "the old install records a blocked state" "blocked" "$(record_field state)"
assert_eq "the old install records the provider-version class" \
  "provider-version" "$(record_field class)"
assert_mentions "the old-install remedy names the installed version" \
  "$(record_field remedy)" "5.3.3"
assert_mentions "the old-install remedy names the required version" \
  "$(record_field remedy)" "5.4.0"

rc="$(prepare_with "$_fixture_plist" present 1 "$_tmp/versions/5.4.0")"
assert_eq "a failing plutil returns 20" "20" "$rc"
assert_eq "the unreadable version records the provider-version class" \
  "provider-version" "$(record_field class)"
assert_mentions "the unreadable-version remedy says the version could not be read" \
  "$(record_field remedy)" "could not be read"

rc="$(prepare_with "$_fixture_plist" present 0 "$_tmp/versions/garbage")"
assert_eq "a garbage version returns 20" "20" "$rc"
assert_mentions "the garbage-version remedy says the version could not be read" \
  "$(record_field remedy)" "could not be read"

rc="$(prepare_with "$_absent_plist" present 0 "$_tmp/versions/5.4.0")"
assert_eq "an absent plist returns 20" "20" "$rc"
assert_eq "the absent plist remedy is the not-installed message" \
  "macFUSE not installed; install via 'brew install --cask macfuse@dev'" \
  "$(record_field remedy)"

rc="$(prepare_with "$_fixture_plist" absent 0 "$_tmp/versions/5.4.0")"
assert_eq "a missing macFUSE CLI returns 20" "20" "$rc"
assert_eq "the missing CLI remedy is the not-installed message" \
  "macFUSE not installed; install via 'brew install --cask macfuse@dev'" \
  "$(record_field remedy)"

section "2" "the version source is pinned"

# WHY the exact path: the sibling macfuse.app Info.plist reports 1.0 and would
# block every install as too old, so the probe must read the bundle plist and
# nothing else.
assert_eq "the probe reads the macfuse.fs bundle plist" \
  "/Library/Filesystems/macfuse.fs/Contents/Info.plist" "$(macfuse_info_plist)"

finish_tests
