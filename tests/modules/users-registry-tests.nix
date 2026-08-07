# tests/modules/users-registry-tests.nix — users-registry.nix loader and platform resolution.

let
  lib = import <nixpkgs/lib>;
  repoRoot = ../..;
  usersMacOS = import ../../src/modules/lib/users-registry.nix {
    inherit lib repoRoot;
    hostName = "MacBook";
  };
  usersWindows = import ../../src/modules/lib/users-registry.nix {
    inherit lib repoRoot;
    hostName = "Windows";
  };
  usersNixOS = import ../../src/modules/lib/users-registry.nix {
    inherit lib repoRoot;
    hostName = "NixOS";
  };

  inherit (import ../lib.nix) assert';

  userNames = builtins.attrNames usersMacOS;

  googleDriveReplica =
    replica: builtins.head (builtins.filter (entry: (entry.id or "") == "GoogleDrive") replica);

  icloudReplica =
    replica: builtins.head (builtins.filter (entry: (entry.id or "") == "iCloud") replica);

  test_discovers_polyipseity_user = assert' (builtins.elem "polyipseity" userNames) "users-registry.nix must discover polyipseity from src/users/";

  test_excludes_default_and_schemas_dirs = assert' (
    !(builtins.elem "default" userNames) && !(builtins.elem "schemas" userNames)
  ) "users-registry.nix must not treat default/ or schemas/ as users";

  test_merges_default_and_user_profile = assert' (
    usersMacOS.polyipseity.isPrimary == true
    && usersMacOS.polyipseity.homeDirectory == "/Users/polyipseity"
  ) "users-registry.nix must merge profile.json default + polyipseity overrides";

  test_resolves_cloud_drive_local_path_per_platform = assert' (
    let
      mounts = usersMacOS.polyipseity.cloudDrives.mounts;
      googleDrive = builtins.head (builtins.filter (m: (m.id or "") == "GoogleDrive") mounts);
    in
    googleDrive.localPath == "clouds/GoogleDrive"
    &&
      (googleDriveReplica usersWindows.polyipseity.cloudDrives.replicas).localPath
      == "clouds\\GoogleDriveReplica"
  ) "users-registry.nix must resolve platform-keyed cloud drive localPath values";

  test_resolves_replica_enable_per_platform = assert' (
    (googleDriveReplica usersMacOS.polyipseity.cloudDrives.replicas).enable == false
    && (googleDriveReplica usersWindows.polyipseity.cloudDrives.replicas).enable == true
  ) "users-registry.nix must resolve platform-keyed replica enable flags";

  test_resolves_replica_readwrite_per_platform = assert' (
    (icloudReplica usersMacOS.polyipseity.cloudDrives.replicas).readWrite == true
    && (icloudReplica usersWindows.polyipseity.cloudDrives.replicas).readWrite == false
  ) "users-registry.nix must resolve platform-keyed replica readWrite flags";

  test_assembles_vm_guest_domain = assert' (
    usersMacOS.polyipseity.vmGuest.usernameSecretKey == "vm_guest_username"
    && usersMacOS.polyipseity.vmGuest.passwordSecretKey == "vm_guest_password"
  ) "users-registry.nix must assemble vmGuest from src/users/<username>/vm-guest.json";

  test_assembles_windows_dsc_config_files = assert' (
    builtins.elem "env.dsc.yml" usersWindows.polyipseity.dscConfigFiles
    && builtins.elem "wallpaper.dsc.yml" usersWindows.polyipseity.dscConfigFiles
  ) "users-registry.nix must expose dscConfigFiles from windows.json on Windows";

  test_password_store_path_available = assert' (
    usersNixOS.polyipseity.passwordStore.path == "~/dev/monorepo-private/self/passwords"
  ) "users-registry.nix must merge password-store.json for env-catalog consumers";

  allTests = [
    test_discovers_polyipseity_user
    test_excludes_default_and_schemas_dirs
    test_merges_default_and_user_profile
    test_resolves_cloud_drive_local_path_per_platform
    test_resolves_replica_enable_per_platform
    test_resolves_replica_readwrite_per_platform
    test_assembles_vm_guest_domain
    test_assembles_windows_dsc_config_files
    test_password_store_path_available
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} users-registry tests passed";
}
