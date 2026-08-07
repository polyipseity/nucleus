# tests/modules/cloud-mount-paths-tests.nix — Cloud mount path invariants.

let
  inherit (import ../lib.nix) assert' containsRegex;

  setupScript = builtins.readFile ../../src/scripts/services/cloud-drives-setup.sh;

  test_mount_paths_fail_on_symlinks = assert' (
    containsRegex "is a symlink; fix manually and re-apply" setupScript
    && containsRegex "_cd_ensure_real_directory" setupScript
    && containsRegex "mkdir -p" setupScript
  ) "mount paths must fail when a managed directory path is a symlink";

  allTests = [ test_mount_paths_fail_on_symlinks ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud mount path tests passed";
}
