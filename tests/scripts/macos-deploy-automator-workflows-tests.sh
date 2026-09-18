#!/usr/bin/env bash
# Tests for the undeclared-bundle pruning in
# src/hosts/MacBook/scripts/macos-deploy-automator-workflows.sh.
#
# Pruning is what makes a renamed or removed preset disappear: macOS
# re-registers an NSServicesStatus entry for every workflow bundle still present
# in ~/Library/Services, so a bundle left behind keeps its old label in Finder
# Quick Actions and the Services menu even after the deployer rewrites the
# enablement dictionary.  The suite extracts the pruner from the activation
# script and runs it against fixture services directories; the script body is
# never executed, because a real run copies bundles, calls setIcon and mdimport,
# and rewrites the system preferences domain.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

DEPLOY_SCRIPT="$SCRIPT_DIR/../../src/hosts/MacBook/scripts/macos-deploy-automator-workflows.sh"

# Fail closed: without the extracted function every case below would call an
# undefined command, and the "kept" cases would report success for pruning that
# never ran.
PRUNE_FUNC="$(extract_func automator_prune_stale_workflows "$DEPLOY_SCRIPT")"
if [ -z "$PRUNE_FUNC" ]; then
  assert_fail "prune function is defined in the deploy script" \
    "extract_func automator_prune_stale_workflows returned nothing from $DEPLOY_SCRIPT"
  finish_tests
fi

# The pruner reads CFBundleIdentifier through the `defaults` binary handed to it,
# never through /usr/bin/defaults, so the suite can control the answer by passing
# a stub instead of touching the real preferences domain.
eval "$PRUNE_FUNC"

# make_defaults_stub <path> <shell body> — install an executable `defaults` stub.
# Bodies used below: print an identifier, `exit 1` (unreadable), `exit 0` (empty).
make_defaults_stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$1"
  chmod +x "$1"
}

# make_bundle <services_dir> <bundle_name> <identifier> — write a minimal
# .workflow bundle carrying a CFBundleIdentifier.
make_bundle() {
  local bundle="$1/$2"
  mkdir -p "$bundle/Contents"
  cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$3</string>
</dict>
</plist>
EOF
}

# write_desired <file> [bundle_name ...] — one declared directory name per line,
# which is exactly the `jq -r '.[].dir'` shape the deployer feeds the pruner
# (suffix included).
write_desired() {
  local file="$1"
  shift
  : >"$file"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"$file"
  fi
}

# installed_bundles <services_dir> — sorted bare names of the bundles still on disk.
installed_bundles() {
  find "$1" -mindepth 1 -maxdepth 1 -name '*.workflow' | sed 's|.*/||' | sort
}

# assert_installed <test_name> <services_dir> <expected names, newline separated>
assert_installed() {
  local test_name="$1" services_dir="$2" expected="$3" actual
  actual="$(installed_bundles "$services_dir")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual]"
  fi
}

test_prune_removes_an_undeclared_nucleus_bundle() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Nucleus Stale.workflow" "com.nucleus.stale"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "printf '%s\n' 'com.nucleus.stale'"
  desired="$work/desired"
  write_desired "$desired"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune removes an undeclared bundle with a nucleus identifier" \
    "$services" ""
  rm -rf "$work"
}

test_prune_keeps_a_declared_bundle() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Nucleus Keep.workflow" "com.nucleus.keep"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "printf '%s\n' 'com.nucleus.keep'"
  desired="$work/desired"
  write_desired "$desired" "Nucleus Keep.workflow"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune keeps a declared bundle" "$services" "Nucleus Keep.workflow"
  rm -rf "$work"
}

test_prune_keeps_a_foreign_bundle() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Some App.workflow" "com.apple.Foo"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "printf '%s\n' 'com.apple.Foo'"
  desired="$work/desired"
  write_desired "$desired"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune keeps an undeclared bundle with a foreign identifier" \
    "$services" "Some App.workflow"
  rm -rf "$work"
}

test_prune_keeps_a_bundle_with_an_unreadable_identifier() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Nucleus Unreadable.workflow" "com.nucleus.unreadable"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "exit 1"
  desired="$work/desired"
  write_desired "$desired"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune keeps a bundle whose identifier cannot be read" \
    "$services" "Nucleus Unreadable.workflow"
  rm -rf "$work"
}

test_prune_keeps_a_bundle_with_an_empty_identifier() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Nucleus Anonymous.workflow" ""
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "exit 0"
  desired="$work/desired"
  write_desired "$desired"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune keeps a bundle whose identifier is empty" \
    "$services" "Nucleus Anonymous.workflow"
  rm -rf "$work"
}

test_prune_removes_exactly_the_undeclared_nucleus_bundles() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Alpha.workflow" "com.nucleus.alpha"
  make_bundle "$services" "Old Beta.workflow" "com.nucleus.beta"
  make_bundle "$services" "Foreign.workflow" "com.apple.Foo"
  defaults="$work/defaults"
  # One stub answers per bundle, the way the real `defaults read` does, so a
  # single prune run sees a directory whose bundles carry different identifiers.
  cat >"$defaults" <<'STUB'
#!/bin/sh
case "$2" in
*/Alpha.workflow/*) printf '%s\n' 'com.nucleus.alpha' ;;
*/Old\ Beta.workflow/*) printf '%s\n' 'com.nucleus.beta' ;;
*/Foreign.workflow/*) printf '%s\n' 'com.apple.Foo' ;;
*) exit 1 ;;
esac
STUB
  chmod +x "$defaults"
  desired="$work/desired"
  write_desired "$desired" "Alpha.workflow"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune removes exactly the undeclared nucleus bundles" \
    "$services" "$(printf '%s\n%s\n' 'Alpha.workflow' 'Foreign.workflow')"
  rm -rf "$work"
}

test_prune_does_not_treat_a_partially_matching_declared_name_as_a_declaration() {
  local work services defaults desired
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  make_bundle "$services" "Nucleus Keep.workflow" "com.nucleus.keep"
  # A declared name that is only a prefix of the installed bundle name: the
  # renamed preset has to go.
  make_bundle "$services" "Nucleus Keep.workflow Extra.workflow" "com.nucleus.extra"
  # An installed name that is only a prefix of the declared bundle name is the
  # case that `grep -x` alone rejects: `grep -F` without -x finds it inside the
  # longer declared line and would keep a bundle that is no longer declared.
  make_bundle "$services" "Keep.workflow" "com.nucleus.short"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "printf '%s\n' 'com.nucleus.any'"
  desired="$work/desired"
  write_desired "$desired" "Nucleus Keep.workflow"

  automator_prune_stale_workflows "$services" "$desired" "$defaults"

  assert_installed "prune does not treat a partially matching declared name as a declaration" \
    "$services" "Nucleus Keep.workflow"
  rm -rf "$work"
}

test_prune_tolerates_a_missing_services_directory() {
  local work defaults desired probe_log status=0 probes
  work="$(mktemp -d)"
  probe_log="$work/probed.log"
  defaults="$work/defaults"
  # The stub records every bundle it is asked about, so "no-op" is provable:
  # without the existence guard the pruner would probe (and `rm -rf`) the literal
  # "<dir>/*.workflow" a non-matching glob leaves behind.
  make_defaults_stub "$defaults" "printf '%s\n' \"\$*\" >>\"$probe_log\""
  desired="$work/desired"
  write_desired "$desired"

  # Before the first deploy ~/Library/Services does not exist yet; the pruner
  # must not fail the activation step.
  automator_prune_stale_workflows "$work/AbsentServices" "$desired" "$defaults" || status=$?
  probes="$(cat "$probe_log" 2>/dev/null || true)"

  if [ "$status" -eq 0 ] && [ -z "$probes" ]; then
    assert_pass "prune is a no-op for a missing services directory"
  else
    assert_fail "prune is a no-op for a missing services directory" \
      "expected exit 0 and no bundle probed, got exit $status with probes [$probes]"
  fi
  rm -rf "$work"
}

test_prune_tolerates_an_empty_services_directory() {
  local work services defaults desired probe_log status=0 probes
  work="$(mktemp -d)"
  services="$work/Services"
  mkdir -p "$services"
  probe_log="$work/probed.log"
  defaults="$work/defaults"
  make_defaults_stub "$defaults" "printf '%s\n' \"\$*\" >>\"$probe_log\""
  desired="$work/desired"
  write_desired "$desired"

  automator_prune_stale_workflows "$services" "$desired" "$defaults" || status=$?
  probes="$(cat "$probe_log" 2>/dev/null || true)"

  if [ "$status" -eq 0 ] && [ -z "$probes" ]; then
    assert_pass "prune is a no-op for an empty services directory"
  else
    assert_fail "prune is a no-op for an empty services directory" \
      "expected exit 0 and no bundle probed, got exit $status with probes [$probes]"
  fi
  rm -rf "$work"
}

# ---- Undeclared-bundle pruning ----

test_prune_removes_an_undeclared_nucleus_bundle
test_prune_keeps_a_declared_bundle
test_prune_keeps_a_foreign_bundle
test_prune_keeps_a_bundle_with_an_unreadable_identifier
test_prune_keeps_a_bundle_with_an_empty_identifier
test_prune_removes_exactly_the_undeclared_nucleus_bundles
test_prune_does_not_treat_a_partially_matching_declared_name_as_a_declaration
test_prune_tolerates_a_missing_services_directory
test_prune_tolerates_an_empty_services_directory

finish_tests
