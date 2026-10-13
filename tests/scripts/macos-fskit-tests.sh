#!/usr/bin/env bash
# Tests for src/scripts/lib/macos-fskit.sh, the FSKit module-state probe.
#
# The probe decides whether a macFUSE-dependent entry counts as present, so its
# contract matters in both directions: a readable list must answer
# enabled/disabled precisely, and an unreadable one must answer "unknown" rather
# than "disabled" (a probe failure that reads as a missing module would drop an
# entry that is actually fine).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/macos-fskit.sh
. "$REPO_ROOT/src/scripts/lib/macos-fskit.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin" "$_tmp/home/Library/Group Containers/group.com.apple.fskit.settings"
export HOME="$_tmp/home"
readonly _tmp
_plist="$(fskit_settings_plist)"
export PATH="$_tmp/bin:$PATH"

export FAKE_PLUTIL_STATUS FAKE_FSKIT_LISTING

cat >"$_tmp/bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
case "${1:-}" in
-p)
  printf '%s\n' "${FAKE_FSKIT_LISTING:-}"
  exit "${FAKE_PLUTIL_STATUS:-0}"
  ;;
esac
exit 1
FAKE_PLUTIL
chmod +x "$_tmp/bin/plutil"

assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

section "macos-fskit" "module state probe"

: >"$_plist"
FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
  1 => "io.macfuse.app.fsmodule.macfuse"
]'
assert_eq "a listed module reads as enabled" "enabled" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"
assert_eq "an unlisted module reads as disabled" "disabled" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse-other)"

FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
]'
assert_eq "a list without the module reads as disabled" "disabled" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"

# WHY: the probe gates a presence decision, so a failed probe must not read as a
# missing module; that would drop an entry that is actually fine.
FAKE_FSKIT_LISTING=""
FAKE_PLUTIL_STATUS=1
assert_eq "a failed probe reads as unknown" "unknown" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"
FAKE_PLUTIL_STATUS=0

rm -f "$_plist"
assert_eq "a missing module list reads as unknown" "unknown" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"
: >"$_plist"

finish_tests
