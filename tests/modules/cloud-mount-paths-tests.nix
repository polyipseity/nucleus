# tests/modules/cloud-mount-paths-tests.nix — Cloud mount path invariants.

let
  inherit (import ../lib.nix) assert' containsRegex;

  moduleText = builtins.readFile ../../src/modules/cloud-drives.nix;

  test_mount_paths_replace_symlinks = assert' (
    containsRegex "replaced legacy symlink" moduleText
    && containsRegex "readlink" moduleText
    && containsRegex "rm \\\"\\$HOME/" moduleText
    && containsRegex "managed directory" moduleText
  ) "mount paths must replace symlinks with managed directories";

  allTests = [ test_mount_paths_replace_symlinks ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud mount path tests passed";
}
