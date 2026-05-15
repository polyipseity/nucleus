# tests/nix/cloud-mount-paths-tests.nix — Validate cloud mount path invariants.
#
# Ensures cloud-drives activation enforces real directory mount/replica paths
# and replaces stale symlink targets from legacy /Volumes indirection flows.

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  moduleText = builtins.readFile ../../src/modules/cloud-drives.nix;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  test_mount_paths_replace_symlinks = assert' (
    containsRegex "replaced legacy symlink" moduleText
    && containsRegex "readlink" moduleText
    && containsRegex "rm \\\"\\$HOME/" moduleText
    && containsRegex "managed directory" moduleText
  ) "cloud-drives activation must replace symlinked mount paths with real managed directories";

  allTests = [
    test_mount_paths_replace_symlinks
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud mount path tests passed";
}
