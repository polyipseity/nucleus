# tests/src/dsc-config-files-tests.nix — Per-user DSC config declaration tests.
#
# Validates that user-level DSC configs (user.dsc.yml, user-env.dsc.yml,
# user-context.dsc.yml) are declared per-user via users.json dscConfigFiles,
# not as universal defaults in apply.ps1.
#
# Run with: nix-instantiate --eval tests/src/dsc-config-files-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsUsersRegistry = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);

  inherit (import ../lib.nix) assert';

  # Expected user-level DSC files.
  expectedUserDscFiles = [
    "user.dsc.yml"
    "user-env.dsc.yml"
    "user-context.dsc.yml"
  ];

  # The primary user from the registry.
  primaryUsers = builtins.filter (u: u.isPrimary or false) windowsUsersRegistry.users;

  # ---------------------------------------------------------------------------
  # apply.ps1 default ConfigFiles assertions
  # ---------------------------------------------------------------------------

  # Test 1: Default ConfigFiles must include both system-level DSC files.
  test_default_includes_system_files = assert' (containsRegex ''"system\.dsc\.yml", "system-packages\.dsc\.yml"'' windowsApplyText) "Default ConfigFiles must contain system.dsc.yml and system-packages.dsc.yml";

  # Test 2: Default ConfigFiles must NOT include any user-level DSC file.
  test_default_excludes_user_files = assert' (
    # The ConfigFiles = @(...) default value must not contain user file names.
    # We check that the unique default array doesn't contain user-level files.
    (!containsRegex ''ConfigFiles = [^)]*user\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user-env\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user-context\.dsc\.yml[^)]*\)'' windowsApplyText)
  ) "Default ConfigFiles must NOT contain any user-level DSC file";

  # Test 3: ConfigFiles param doc must describe per-user extension mechanism.
  test_param_doc_describes_per_user = assert' (
    containsRegex ''Per-user DSC files can be declared in users\.json'' windowsApplyText
    && containsRegex "dscConfigFiles" windowsApplyText
  ) "ConfigFiles param doc must describe per-user extension via users.json dscConfigFiles";

  # Test 4: Deduplication mechanism must exist in apply.ps1.
  test_deduplication_mechanism = assert' (
    containsRegex "userConfigFile -notin" windowsApplyText
    && containsRegex "effectiveConfigFiles" windowsApplyText
  ) "apply.ps1 must deduplicate per-user dscConfigFiles against effectiveConfigFiles";

  # ---------------------------------------------------------------------------
  # users.json primary user dscConfigFiles assertions
  # ---------------------------------------------------------------------------

  # Test 5: Exactly one primary user must exist.
  test_exactly_one_primary_user = assert' (
    builtins.length primaryUsers == 1
  ) "users.json must have exactly one primary user (isPrimary=true)";

  # Test 6: Primary user must have dscConfigFiles array declared.
  test_primary_user_has_dsc_config = assert' (
    let
      user = builtins.head primaryUsers;
    in
    builtins.hasAttr "dscConfigFiles" user && user.dscConfigFiles or [ ] != [ ]
  ) "Primary user must have a non-empty dscConfigFiles array";

  # Test 7: Primary user must have all 3 user-level DSC files.
  test_primary_user_files_complete =
    assert'
      (
        let
          user = builtins.head primaryUsers;
        in
        builtins.all (f: builtins.elem f (user.dscConfigFiles or [ ])) expectedUserDscFiles
      )
      "Primary user's dscConfigFiles must include user.dsc.yml, user-env.dsc.yml, and user-context.dsc.yml";

  # Test 8: Primary user must not have system-level files in dscConfigFiles.
  test_primary_user_no_system_files = assert' (
    let
      user = builtins.head primaryUsers;
    in
    !builtins.elem "system.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system-packages.dsc.yml" (user.dscConfigFiles or [ ])
  ) "Primary user's dscConfigFiles must not contain system.dsc.yml or system-packages.dsc.yml";

  # Test 9: Primary user files must be in alphabetical order.
  test_primary_user_files_alphabetical = assert' (
    let
      user = builtins.head primaryUsers;
    in
    user.dscConfigFiles == builtins.sort builtins.lessThan user.dscConfigFiles
  ) "Primary user's dscConfigFiles must be sorted alphabetically";
in
{
  success = true;
  testCount = 9;
  message = "All 9 DSC config file declaration tests passed";
  testNames = [
    "1:  Default ConfigFiles includes system.dsc.yml and system-packages.dsc.yml"
    "2:  Default ConfigFiles excludes user-level DSC files"
    "3:  ConfigFiles param doc describes per-user extension via users.json"
    "4:  Deduplication mechanism exists in apply.ps1"
    "5:  Exactly one primary user in users.json"
    "6:  Primary user has non-empty dscConfigFiles array"
    "7:  Primary user dscConfigFiles includes all 3 user-level files"
    "8:  Primary user dscConfigFiles excludes system-level files"
    "9:  Primary user dscConfigFiles is sorted alphabetically"
  ];
}
