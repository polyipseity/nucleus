# tests/modules/symlinks-tests.nix — Per-user symlink wiring (behavioral).
#
# Validates that the users-registry correctly loads and structures per-user
# symlink data from fixture JSON. No grep assertions — all checks evaluate
# loaded data.

let
  fixtures = import ../fixtures { };
  inherit (fixtures) fixtureUsername loadFixtureRegistry;

  inherit (import ../lib.nix) assert';

  usersMacBook = loadFixtureRegistry "MacBook";
  usersWindows = loadFixtureRegistry "Windows";

  fixtureUser = usersMacBook.${fixtureUsername};
  fixtureSymlinks = fixtureUser.symlinks;

  # Behavioral: test-user must have symlinks on both platforms.
  test_user_has_symlinks_macbook = assert' (
    fixtureSymlinks != [ ]
  ) "test-user must have symlinks on MacBook";

  test_user_has_symlinks_windows = assert' (
    usersWindows.${fixtureUsername}.symlinks != [ ]
  ) "test-user must have symlinks on Windows";

  # Behavioral: symlink entries must have path and targets.
  test_symlink_has_path = assert' (builtins.all (
    s: s ? path
  ) fixtureSymlinks) "Each symlink entry must have a path field";

  test_symlink_has_targets = assert' (builtins.all (
    s: s ? targets
  ) fixtureSymlinks) "Each symlink entry must have a targets field";

  # Behavioral: targets must include all three host keys.
  test_symlink_targets_include_all_hosts = assert' (
    let
      first = builtins.head fixtureSymlinks;
      targets = first.targets;
    in
    targets ? MacBook && targets ? NixOS && targets ? Windows
  ) "Symlink targets must include MacBook, NixOS, and Windows";

  # Behavioral: specific path value from fixture data.
  test_fixture_data_path = assert' (
    (builtins.head fixtureSymlinks).path == "data"
  ) "Fixture symlink path must be 'data'";

  allTests = [
    test_user_has_symlinks_macbook
    test_user_has_symlinks_windows
    test_symlink_has_path
    test_symlink_has_targets
    test_symlink_targets_include_all_hosts
    test_fixture_data_path
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} symlinks tests passed";
}
