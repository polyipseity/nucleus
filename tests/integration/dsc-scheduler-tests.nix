# tests/integration/dsc-scheduler-tests.nix — Content assertions for the Windows
# DSC scheduler configuration (scheduler.dsc.yml), specifically the gc-weekly
# scheduled task and its guard removal.
#
# Run with: nix-instantiate --eval tests/integration/dsc-scheduler-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  # Negation: assert that a pattern is NOT present.
  notContainsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) == null;

  windowsSchedulerDscText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
in

# gc-weekly task exists
assert containsRegex "gc-weekly" windowsSchedulerDscText;
assert containsRegex "GcScript" windowsSchedulerDscText;
assert containsRegex "gc\\.ps1" windowsSchedulerDscText;

# Test-Path $GcScript guard was removed (commit 0d43be2)
assert notContainsRegex "Test-Path.*GcScript" windowsSchedulerDscText;

true
