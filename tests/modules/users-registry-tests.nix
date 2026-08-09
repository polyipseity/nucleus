# tests/modules/users-registry-tests.nix — users-registry.nix loader and platform resolution.

let
  fixtures = import ../fixtures/fixtures.nix { };
  inherit (fixtures) fixtureUsername loadFixtureRegistry;

  usersMacBook = loadFixtureRegistry "MacBook";
  usersWindows = loadFixtureRegistry "Windows";
  usersNixOS = loadFixtureRegistry "NixOS";

  inherit (import ../lib.nix) assert';

  userNames = builtins.attrNames usersMacBook;
  fixtureUser = usersMacBook.${fixtureUsername};

  googleDriveReplica =
    replica: builtins.head (builtins.filter (entry: (entry.id or "") == "GoogleDrive") replica);

  icloudReplica =
    replica: builtins.head (builtins.filter (entry: (entry.id or "") == "iCloud") replica);

  test_discovers_fixture_user = assert' (builtins.elem fixtureUsername userNames) "users-registry.nix must discover test-user from fixture src/users/";

  test_excludes_default_dir = assert' (
    !(builtins.elem "default" userNames)
  ) "users-registry.nix must not treat default/ as a user";

  test_merges_default_and_user_profile = assert' (
    fixtureUser.isPrimary == true && fixtureUser.homeDirectory == "/Users/test-user"
  ) "users-registry.nix must merge profile.json default + test-user overrides";

  test_resolves_cloud_drive_local_path_per_platform = assert' (
    let
      mounts = usersMacBook.${fixtureUsername}.cloudDrives.mounts;
      googleDrive = builtins.head (builtins.filter (m: (m.id or "") == "GoogleDrive") mounts);
    in
    googleDrive.localPath == "clouds/GoogleDrive"
    &&
      (googleDriveReplica usersWindows.${fixtureUsername}.cloudDrives.replicas).localPath
      == "clouds\\GoogleDriveReplica"
  ) "users-registry.nix must resolve host-keyed cloud drive localPath values";

  test_resolves_replica_enable_per_platform = assert' (
    (googleDriveReplica usersMacBook.${fixtureUsername}.cloudDrives.replicas).enable == false
    && (googleDriveReplica usersWindows.${fixtureUsername}.cloudDrives.replicas).enable == false
  ) "users-registry.nix must resolve replica enable flags from default cloud-drives policy";

  test_resolves_replica_readwrite_per_platform = assert' (
    (icloudReplica usersMacBook.${fixtureUsername}.cloudDrives.replicas).readWrite == true
    && (icloudReplica usersWindows.${fixtureUsername}.cloudDrives.replicas).readWrite == false
  ) "users-registry.nix must resolve host-keyed replica readWrite flags";

  test_assembles_vm_guest_domain = assert' (
    fixtureUser.vmGuest.usernameSecretKey == "vm_guest_username"
    && fixtureUser.vmGuest.passwordSecretKey == "vm_guest_password"
  ) "users-registry.nix must assemble vmGuest from src/users/<username>/vm-guest.json";

  test_assembles_windows_dsc_config_files = assert' (
    builtins.elem "env.dsc.yml" usersWindows.${fixtureUsername}.dscConfigFiles
    && builtins.elem "wallpaper.dsc.yml" usersWindows.${fixtureUsername}.dscConfigFiles
  ) "users-registry.nix must expose dscConfigFiles from windows.json on Windows";

  test_password_store_path_available = assert' (
    usersNixOS.${fixtureUsername}.passwordStore.path == "~/fixture/passwords"
  ) "users-registry.nix must merge password-store.json for env-catalog consumers";

  allTests = [
    test_discovers_fixture_user
    test_excludes_default_dir
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
