# tests/integration/dsc-scheduler-tests.nix — Content assertions for the Windows DSC scheduler configuration.

let
  inherit (import ../lib.nix) containsRegex;

  notContainsRegex = pattern: haystack: !containsRegex pattern haystack;

  windowsSchedulerDscText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
in

# gc-weekly task exists
assert containsRegex "gc-weekly" windowsSchedulerDscText;
assert containsRegex "GcScript" windowsSchedulerDscText;
assert containsRegex "gc\\.ps1" windowsSchedulerDscText;

# Test-Path $GcScript guard was removed (commit 0d43be2)
assert notContainsRegex "Test-Path.*GcScript" windowsSchedulerDscText;

{
  success = true;
  message = "DSC scheduler configuration tests passed";
}
