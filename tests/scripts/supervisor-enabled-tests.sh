#!/usr/bin/env bash
# supervisor_enabled — the REAL launchd and systemd predicates.
#
# The regression this guards: the service-watchdog suite's mock of
# `supervisor_enabled` derives "enabled" from test knobs and never consults the
# machine, so it substitutes for the function under test and can prove nothing
# about it. Two real defects shipped green behind that mock — a launchd predicate
# that read a plist key nothing in the product writes (so macOS's only disable
# mechanism, `launchctl disable`, was invisible and Rule 1 never skipped a
# user-disabled job), and a systemd predicate that read an EMPTY `is-enabled`
# reply as enabled where the previous exit-code form failed closed.
#
# This suite therefore stubs only the EXTERNAL COMMAND (`launchctl`, `systemctl`)
# and always calls the real `supervisor_enabled`. Stubbing the function itself is
# the defect being closed here.
#
# Both adapters deliberately define the same `supervisor_enabled` name — in
# production the watchdog sources exactly one of them. Sourcing both into one
# shell would silently let the last one win, so every probe below runs in a
# subshell that sources ONLY the adapter under test.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

LAUNCHD_LIB="$SCRIPT_DIR/../../src/scripts/lib/supervisor-launchd.sh"
SYSTEMD_LIB="$SCRIPT_DIR/../../src/scripts/lib/supervisor-systemd.sh"

UID_N="$(id -u)"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
ARGS_LOG="$HOME/launchctl-args.log"
# Captured before the stub below shadows it: the domain-correctness case probes
# the REAL override DB.
REAL_LAUNCHCTL="$(command -v launchctl || true)"

# --- external-command stubs (never the predicate) ----------------------------
# FAKE_PRINT_DISABLED — the exact reply shape of `launchctl print-disabled`,
# which lists every overridden label in both directions.
FAKE_PRINT_DISABLED=''
# FAKE_IS_ENABLED — the exact reply shape of `systemctl is-enabled`.
FAKE_IS_ENABLED=''

launchctl() {
  printf '%s\n' "${1:-}" "${2:-}" >>"$ARGS_LOG"
  case "${1:-}" in
  print-disabled) printf '%s' "$FAKE_PRINT_DISABLED" ;;
  *) return 1 ;;
  esac
}

systemctl() {
  printf '%s\n' "$FAKE_IS_ENABLED"
}

# launchd_enabled_state <target> [scope] — the REAL launchd predicate's verdict.
launchd_enabled_state() {
  (
    # shellcheck source=../../src/scripts/lib/supervisor-launchd.sh
    . "$LAUNCHD_LIB"
    if supervisor_enabled "$@"; then printf 'enabled'; else printf 'not-enabled'; fi
  )
}

# systemd_enabled_state <unit> [scope] — the REAL systemd predicate's verdict.
systemd_enabled_state() {
  (
    # shellcheck source=../../src/scripts/lib/supervisor-systemd.sh
    . "$SYSTEMD_LIB"
    if supervisor_enabled "$@"; then printf 'enabled'; else printf 'not-enabled'; fi
  )
}

# write_plist <label> [extra-dict-entries] — a minimal but real plist.
write_plist() { # <label> [extra]
  mkdir -p "$LAUNCHAGENTS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string>%s</dict></plist>\n' \
    "$1" "${2:-}" >"$LAUNCHAGENTS/$1.plist"
}

# assert_state <test-name> <expected> <producer> <target> [unit path] [scope]
assert_state() { # <name> <expected> <producer> <target> [unit path] [scope]
  local name="$1" expected="$2" producer="$3" actual
  # Every trailing argument is forwarded so the producer keeps the predicate's
  # own arity (<target> [unit path] [scope]) instead of a hard-coded two.
  actual="$("$producer" "${@:4}")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$name"
  else
    assert_fail "$name" "expected $expected, got $actual"
  fi
}

# override_reply <line...> — a print-disabled reply containing the given entries,
# each already in the command's own `"<label>" => enabled|disabled` shape.
override_reply() {
  local out=$'\tdisabled services = {\n' entry
  for entry in "$@"; do
    out+="$(printf '\t\t%s\n' "$entry")"
  done
  FAKE_PRINT_DISABLED="${out}"$'\t}\n'
}

# ============================================================================
section 1 "the predicate under test is the real implementation"
# ============================================================================
# WHY: F-3's root cause was a suite-local override of the function under test.
if (
  # shellcheck source=../../src/scripts/lib/supervisor-launchd.sh
  . "$LAUNCHD_LIB"
  declare -f supervisor_enabled | grep -q '_launchd_override_state'
); then
  assert_pass "the launchd predicate body under test is the real implementation"
else
  assert_fail "the launchd predicate body under test is the real implementation" \
    "the body does not call _launchd_override_state"
fi
if (
  # shellcheck source=../../src/scripts/lib/supervisor-systemd.sh
  . "$SYSTEMD_LIB"
  declare -f supervisor_enabled | grep -q '_systemd_scope_args'
); then
  assert_pass "the systemd predicate body under test is the real implementation"
else
  assert_fail "the systemd predicate body under test is the real implementation" \
    "the body does not call _systemd_scope_args"
fi

# ============================================================================
section 2 "launchd: the disable lives in the override DB, not the plist"
# ============================================================================
write_plist "local.probe"
override_reply '"local.other" => enabled' '"local.probe" => disabled'
assert_state "explicitly disabled label is NOT enabled" \
  "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""
# WHY: THE F-1 regression. Pre-fix, a keyless plist read as enabled because the
#   predicate consulted a plist key nothing writes; the override DB was ignored.
if [ "$(launchd_enabled_state "gui/$UID_N/local.probe" "")" = "not-enabled" ]; then
  assert_pass "F-1: a keyless plist with a disabled override is caught"
else
  assert_fail "F-1: a keyless plist with a disabled override is caught" \
    "the predicate ignored the override DB and reported enabled"
fi

override_reply '"local.probe" => enabled'
assert_state "an explicitly enabled override is enabled" \
  "enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""

override_reply '"local.other" => enabled'
assert_state "a booted-out job absent from the DB is enabled (Rule 4 can revive it)" \
  "enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""
# WHY: this is the fix the review proved must SURVIVE the F-1 repair. The previous
#   loaded-ness form reported SKIP here, making Rule 4 unreachable for exactly the
#   case it exists for.
if [ "$(launchd_enabled_state "gui/$UID_N/local.probe" "")" = "enabled" ]; then
  assert_pass "the booted-out revivable case still passes"
else
  assert_fail "the booted-out revivable case still passes" \
    "a booted-out, not-disabled job was reported not-enabled"
fi

# ============================================================================
section 3 "launchd: unknown fails closed, absent stays not-enabled"
# ============================================================================
FAKE_PRINT_DISABLED=''
assert_state "an empty override reply fails CLOSED" \
  "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""
FAKE_PRINT_DISABLED=$'something unexpected\n'
assert_state "an unrecognisable override reply fails CLOSED" \
  "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""
# A reply with the header but no entry for this label is the healthy case.
override_reply
assert_state "a header-only reply (no disabled labels) is enabled" \
  "enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""

rm -f "$LAUNCHAGENTS/local.probe.plist"
override_reply
assert_state "an absent plist is NOT enabled" \
  "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""

# ============================================================================
section 4 "launchd: the lookup uses the target's own domain"
# ============================================================================
write_plist "local.probe"
override_reply
: >"$ARGS_LOG"
launchd_enabled_state "gui/$UID_N/local.probe" "" >/dev/null
if grep -qx "print-disabled" "$ARGS_LOG" && grep -qxF "gui/$UID_N" "$ARGS_LOG"; then
  assert_pass "the gui target queries the gui/<uid> override domain"
else
  assert_fail "the gui target queries the gui/<uid> override domain" \
    "launchctl was called with: $(tr '\n' ' ' <"$ARGS_LOG")"
fi

# The system plist lives in /Library/LaunchDaemons, which a test cannot write
# without root, so the predicate would return on the existence check before ever
# reaching the lookup. The gui case above already proved the helper is what the
# lookup actually calls, so the system domain is checked via the helper itself.
system_domain="$(
  # shellcheck source=../../src/scripts/lib/supervisor-launchd.sh
  . "$LAUNCHD_LIB"
  _launchd_domain_target "system/local.probe"
)"
if [ "$system_domain" = "system" ]; then
  assert_pass "the system target resolves to the system override domain"
else
  assert_fail "the system target resolves to the system override domain" \
    "_launchd_domain_target returned '$system_domain'"
fi

# ============================================================================
section 5 "launchd: the ruled trade-off, pinned"
# ============================================================================
# WHY: the plist `Disabled` key is deliberately NOT consulted (nothing in the
#   product writes it). This pins that decision so the trade-off stays visible:
#   a hand-authored plist carrying Disabled=true is reported enabled.
write_plist "local.probe" '<key>Disabled</key><true/>'
override_reply
assert_state "a plist Disabled key is deliberately not consulted" \
  "enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""

# ============================================================================
section 6 "launchd: the REAL override DB (domain correctness, live)"
# ============================================================================
# WHY: the stubs above prove the parsing; only the real command proves the DOMAIN
#   is right. Both branches assert the host-correct expectation, so neither is a
#   skip-guard: on a macOS host the DB must be readable; elsewhere `launchctl`
#   does not exist, which the predicate reports as unknown → not-enabled.
if [ -n "$REAL_LAUNCHCTL" ] && [ "$(uname -s)" = "Darwin" ]; then
  if "$REAL_LAUNCHCTL" print-disabled "gui/$UID_N" >/dev/null 2>&1; then
    assert_pass "the real gui override domain is readable"
  else
    assert_fail "the real gui override domain is readable" \
      "launchctl print-disabled gui/$UID_N failed"
  fi
  if "$REAL_LAUNCHCTL" print-disabled system >/dev/null 2>&1; then
    assert_pass "the real system override domain is readable"
  else
    assert_fail "the real system override domain is readable" \
      "launchctl print-disabled system failed"
  fi
  if "$REAL_LAUNCHCTL" print-disabled "gui/$UID_N" 2>/dev/null |
    grep -Fq '"local.supervisor-enabled-tests-absent" => disabled'; then
    assert_fail "a label absent from the real DB is not reported disabled" \
      "the sandbox label unexpectedly carries a disable override"
  else
    assert_pass "a label absent from the real DB is not reported disabled"
  fi
else
  # No launchctl on this host: the predicate must report unknown → not-enabled.
  FAKE_PRINT_DISABLED=''
  assert_state "without launchctl the state is unknown and fails closed" \
    "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""
fi

# ============================================================================
section 7 "systemd: the reported states"
# ============================================================================
for _state in enabled static indirect alias generated; do
  FAKE_IS_ENABLED="$_state"
  assert_state "systemd '$_state' is enabled" \
    "enabled" systemd_enabled_state "local.unit.service" "" "user"
done
for _state in disabled masked not-found; do
  FAKE_IS_ENABLED="$_state"
  assert_state "systemd '$_state' is NOT enabled" \
    "not-enabled" systemd_enabled_state "local.unit.service" "" "user"
done

# ============================================================================
section 8 "systemd: an empty reply fails closed (F-2)"
# ============================================================================
# WHY: THE F-2 regression. Parsing the output turned an unanswerable state into
#   "enabled"; the previous exit-code form failed closed on the same condition.
FAKE_IS_ENABLED=''
assert_state "an empty is-enabled reply fails CLOSED" \
  "not-enabled" systemd_enabled_state "local.unit.service" "" "user"
if [ "$(systemd_enabled_state "local.unit.service" "" "user")" = "not-enabled" ]; then
  assert_pass "F-2: an unreadable state is not treated as permission to start"
else
  assert_fail "F-2: an unreadable state is not treated as permission to start" \
    "an empty reply was read as enabled"
fi

# ============================================================================
section 9 "launchd: a declared unit path outside the default directory"
# ============================================================================
# WHY (the F5-b case): supervisor_start and supervisor_repair consume the
#   declared unit path, but supervisor_enabled used to derive the DEFAULT path
#   itself (supervisor_unit_path "$target" ""), so a job installed at a declared
#   non-default path read as ABSENT — and Rule 1 SKIPS an absent job forever:
#   never revived, never repaired. One declared policy, two algorithms.
F5B_DIR="$(mktemp -d)"
mkdir -p "$F5B_DIR"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>local.probe</string></dict></plist>\n' \
  >"$F5B_DIR/local.probe.plist"
# The DEFAULT path is deliberately absent, so the next assertion cannot pass
# because a file happens to exist somewhere the old code would have looked.
rm -f "$LAUNCHAGENTS/local.probe.plist"
override_reply

assert_state "control: with the default path absent the job is NOT enabled" \
  "not-enabled" launchd_enabled_state "gui/$UID_N/local.probe" ""

assert_state "a plist at its declared non-default path IS enabled" \
  "enabled" launchd_enabled_state "gui/$UID_N/local.probe" "$F5B_DIR/local.probe.plist"

# systemd addresses units by NAME, so a declared path must not move its verdict.
FAKE_IS_ENABLED='enabled'
assert_state "systemd accepts the declared path in the shared arity and is unaffected" \
  "enabled" systemd_enabled_state "local.unit.service" "$F5B_DIR/local.probe.plist" "user"

rm -rf "$F5B_DIR"

finish_tests
