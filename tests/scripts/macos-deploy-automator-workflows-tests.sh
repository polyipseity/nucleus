#!/usr/bin/env bash
# Tests for src/hosts/MacBook/scripts/macos-deploy-automator-workflows.sh.
#
# Pruning is what makes a renamed or removed preset disappear: macOS
# re-registers an NSServicesStatus entry for every workflow bundle still present
# in ~/Library/Services, so a bundle left behind keeps its old label in Finder
# Quick Actions and the Services menu even after the deployer rewrites the
# enablement dictionary.
#
# Two layers:
#   * pruner cases, which extract automator_prune_stale_workflows and drive it
#     directly against fixture services directories;
#   * one end-to-end case, which runs the whole activation script under a
#     stubbed HOME with stub setIcon/defaults/mdimport binaries.
#
# The pruner-only layer cannot see the call site, so deleting the call (or the
# dictionary write) leaves it green; the end-to-end case is what covers that
# wiring.  The stubs are the reason the deployer takes the macOS system binaries
# as arguments: a hardcoded /usr/bin/defaults would escape them and rewrite the
# real preferences domain.

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

# ---- End-to-end deployment ----

require_command jq "the deployer consumes the workflow list through jq"
JQ_BIN="$(command -v jq)"

# make_store_bundle <store_root> <workflow_dir_name> <identifier> — build a source
# bundle shaped like the derivation output the deployer copies from.
make_store_bundle() {
  local bundle="$1/$2"
  mkdir -p "$bundle/Contents/QuickLook"
  cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$3</string>
</dict>
</plist>
EOF
  : >"$bundle/Contents/QuickLook/Thumbnail.png"
}

# workflow_json_entry <dir> <source> <enablement_key> — one element of the array
# the Nix expression hands the deployer, built with the jq the deployer uses.
workflow_json_entry() {
  # shellcheck disable=SC2016 # reason: jq program text; $dir/$key/$source are jq variables, not shell expansions
  local program='{dir: $dir, enablementKey: $key, source: $source, presentationModesDict: "<dict><key>ContextMenuShortcut</key><true/></dict>"}'
  "$JQ_BIN" -cn \
    --arg dir "$1" \
    --arg source "$2" \
    --arg key "$3" \
    "$program"
}

# make_reading_defaults_stub <path> — a `defaults` that answers an identifier
# query from the bundle's own Info.plist and records every write in
# $DEFAULTS_STUB_RECORD, the way the real binary talks to the preferences domain.
make_reading_defaults_stub() {
  cat >"$1" <<'STUB'
#!/bin/sh
case "$1" in
read)
  awk '/<key>CFBundleIdentifier<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}' "$2.plist"
  ;;
write)
  printf '%s\n' "$*" >>"${DEFAULTS_STUB_RECORD:?DEFAULTS_STUB_RECORD must be set}"
  ;;
*)
  exit 1
  ;;
esac
STUB
  chmod +x "$1"
}

# make_recorder_stub <path> <log> — an executable that appends its argv to <log>.
make_recorder_stub() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$*" >>"$2"
STUB
  chmod +x "$1"
}

test_deploy_script_takes_the_system_binaries_as_arguments() {
  # Without this the end-to-end case below would reach the real /usr/bin/defaults
  # and rewrite this machine's pbs preferences domain.
  local hardcoded
  hardcoded="$(grep -nE '/usr/bin/(defaults|mdimport)' "$DEPLOY_SCRIPT" || true)"
  if [ -z "$hardcoded" ]; then
    assert_pass "deploy script takes the macOS system binaries as arguments"
  else
    assert_fail "deploy script takes the macOS system binaries as arguments" \
      "hardcoded system binary would bypass the test stubs: $hardcoded"
  fi
}

test_deploy_end_to_end_converges_bundles_and_preferences() {
  local work home store services defaults mdimport seticon json record
  local kept prepress stale_unnumbered stale_dotted foreign
  work="$(mktemp -d)"
  home="$work/home"
  store="$work/store"
  services="$home/Library/Services"
  mkdir -p "$services" "$store"

  kept="optimize PDF - (1) default.workflow"
  prepress="optimize PDF - (2) prepress.workflow"
  stale_unnumbered="optimize PDF - default.workflow"
  stale_dotted="optimize PDF - 1. default.workflow"
  foreign="Some App.workflow"

  make_store_bundle "$store" "$kept" "com.nucleus.OptimizePDF.default"
  make_store_bundle "$store" "$prepress" "com.nucleus.OptimizePDF.prepress"
  # Leftovers from the two earlier naming schemes, plus a bundle owned by another
  # application: only the first two may be removed.
  make_bundle "$services" "$stale_unnumbered" "com.nucleus.OptimizePDF.legacy"
  make_bundle "$services" "$stale_dotted" "com.nucleus.OptimizePDF.dotted"
  make_bundle "$services" "$foreign" "com.apple.Foo"

  defaults="$work/defaults"
  make_reading_defaults_stub "$defaults"
  mdimport="$work/mdimport"
  seticon="$work/seticon"
  make_recorder_stub "$mdimport" "$work/mdimport.log"
  make_recorder_stub "$seticon" "$work/seticon.log"
  record="$work/defaults.log"
  export DEFAULTS_STUB_RECORD="$record"

  json="$({
    workflow_json_entry "$kept" "$store/$kept" "com.nucleus.OptimizePDF.default - optimize PDF - (1) default - runWorkflowAsService"
    workflow_json_entry "$prepress" "$store/$prepress" "com.nucleus.OptimizePDF.prepress - optimize PDF - (2) prepress - runWorkflowAsService"
  } | "$JQ_BIN" -sc '.')"

  HOME="$home" bash "$DEPLOY_SCRIPT" "$JQ_BIN" "$json" "$seticon" "$defaults" "$mdimport"

  # 1. The leftovers are gone; declared and foreign bundles survive.
  assert_installed "deploy end-to-end prunes bundles the workflow list no longer declares" \
    "$services" "$(printf '%s\n%s\n%s\n' "$kept" "$prepress" "$foreign" | sort)"

  # 2. Each declared bundle was copied and registered with IconServices/mdimport.
  #    Both logs are read tolerantly: a missing one means the copy loop never ran,
  #    which the assertion below reports instead of aborting the suite.
  local icons metadata
  icons="$(cat "$work/seticon.log" 2>/dev/null || true)"
  metadata="$(cat "$work/mdimport.log" 2>/dev/null || true)"
  if [ "$(printf '%s\n' "$icons" | wc -l | tr -d ' ')" = "2" ] &&
    printf '%s\n' "$icons" | grep -qF "$services/$kept/Contents/QuickLook/Thumbnail.png" &&
    printf '%s\n' "$icons" | grep -qF "$services/$prepress/Contents/QuickLook/Thumbnail.png" &&
    printf '%s\n' "$metadata" | grep -qxF "$services/$kept" &&
    printf '%s\n' "$metadata" | grep -qxF "$services/$prepress"; then
    assert_pass "deploy end-to-end copies every declared bundle and registers its icon and metadata"
  else
    assert_fail "deploy end-to-end copies every declared bundle and registers its icon and metadata" \
      "setIcon [$icons] mdimport [$metadata]"
  fi

  # 3. One dictionary write, holding both declared keys and their presentation
  #    modes — this is the half a deleted write or a broken key accumulation drops.
  local writes
  writes="$(cat "$record" 2>/dev/null || true)"
  if [ "$(printf '%s\n' "$writes" | wc -l | tr -d ' ')" = "1" ] &&
    printf '%s\n' "$writes" | grep -qF 'write pbs NSServicesStatus' &&
    printf '%s\n' "$writes" | grep -qF '<key>com.nucleus.OptimizePDF.default - optimize PDF - (1) default - runWorkflowAsService</key><dict><key>presentation_modes</key><dict><key>ContextMenuShortcut</key><true/></dict></dict>' &&
    printf '%s\n' "$writes" | grep -qF '<key>com.nucleus.OptimizePDF.prepress - optimize PDF - (2) prepress - runWorkflowAsService</key>'; then
    assert_pass "deploy end-to-end writes one NSServicesStatus dict holding every declared enablement key"
  else
    assert_fail "deploy end-to-end writes one NSServicesStatus dict holding every declared enablement key" \
      "expected a single write with both keys, got [$writes]"
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

# ---- End-to-end deployment ----

test_deploy_script_takes_the_system_binaries_as_arguments
test_deploy_end_to_end_converges_bundles_and_preferences

finish_tests
