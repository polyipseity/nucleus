# tests/modules/cloud-mount-paths-tests.nix — Cloud mount path invariants.

let
  inherit (import ../lib.nix) assert' containsRegex;

  # Symlink replacement is implemented by the cloud-drives-setup service script,
  # wired into the module's activation hook; the module itself is declarative.
  setupScript = builtins.readFile ../../src/scripts/services/cloud-drives-setup.sh;

  test_mount_paths_replace_symlinks = assert' (
    containsRegex "replaced legacy symlink" setupScript
    && containsRegex "readlink" setupScript
    && containsRegex "rm \"\\$" setupScript
    && containsRegex "managed directory" setupScript
  ) "mount paths must replace symlinks with managed directories";

  allTests = [ test_mount_paths_replace_symlinks ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud mount path tests passed";
}
