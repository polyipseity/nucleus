# tests/integration/dsc-config-files-tests.nix — Per-user DSC config declaration tests.
#
# Validates that user-level DSC configs (context-manual.dsc.yml,
# context-pdf-opt.dsc.yml, env.dsc.yml, explorer.dsc.yml, screen-saver.dsc.yml,
# shell.dsc.yml, wallpaper.dsc.yml in the user/ folder) are declared per-user
# via src/users/<username>/windows.json dscConfigFiles, not as universal defaults
# in apply.ps1.
#
# Also validates that apply.ps1 prepends "user/" to each dscConfigFiles entry
# and prevents path-traversal escape.
#
let
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  usersRegistry = import ../../src/modules/lib/users-registry.nix {
    lib = import <nixpkgs/lib>;
    repoRoot = ../..;
    hostName = "Windows";
  };

  inherit (import ../lib.nix) assert' containsRegex;

  # Expected user-level DSC files (bare filenames; apply.ps1 prepends "user/").
  expectedUserDscFiles = [
    "context-manual.dsc.yml"
    "context-pdf-opt.dsc.yml"
    "env.dsc.yml"
    "explorer.dsc.yml"
    "screen-saver.dsc.yml"
    "shell.dsc.yml"
    "wallpaper.dsc.yml"
  ];

  primaryUserNames = builtins.filter (name: usersRegistry.${name}.isPrimary or false) (
    builtins.attrNames usersRegistry
  );

  # ---------------------------------------------------------------------------
  # apply.ps1 default ConfigFiles assertions
  # ---------------------------------------------------------------------------

  # Test 1: Default ConfigFiles must include all system-level DSC files (subfolder paths).
  test_default_includes_system_files = assert' (containsRegex ''"system/scheduler\.dsc\.yml", "system/developer-mode\.dsc\.yml", "system/firewall\.dsc\.yml", "system/taskbar\.dsc\.yml", "system/computer-name\.dsc\.yml", "system/long-paths\.dsc\.yml", "system/storage-sense\.dsc\.yml", "system/font-substitutes\.dsc\.yml", "system/remote-desktop\.dsc\.yml", "system/packages\.dsc\.yml"'' windowsApplyText) "Default ConfigFiles must contain all 10 system-level DSC files";

  # Test 2: Default ConfigFiles must NOT include any user-level DSC file.
  test_default_excludes_user_files = assert' (
    (!containsRegex ''ConfigFiles = [^)]*user/context-manual\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/context-pdf-opt\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/env\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/explorer\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/screen-saver\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/shell\.dsc\.yml[^)]*\)'' windowsApplyText)
    && (!containsRegex ''ConfigFiles = [^)]*user/wallpaper\.dsc\.yml[^)]*\)'' windowsApplyText)
  ) "Default ConfigFiles must NOT contain any user-level DSC file";

  # Test 3: ConfigFiles param doc must describe per-user extension mechanism.
  test_param_doc_describes_per_user = assert' (
    (containsRegex ''src/users'' windowsApplyText || containsRegex "dscConfigFiles" windowsApplyText)
    && containsRegex "dscConfigFiles" windowsApplyText
  ) "ConfigFiles param doc must describe per-user extension via src/users/ dscConfigFiles";

  # Test 4: Deduplication mechanism must exist in apply.ps1.
  test_deduplication_mechanism = assert' (
    containsRegex "resolvedConfigFile -notin" windowsApplyText
    && containsRegex "effectiveConfigFiles" windowsApplyText
  ) "apply.ps1 must deduplicate per-user dscConfigFiles against effectiveConfigFiles";

  # ---------------------------------------------------------------------------
  # src/users/ primary user dscConfigFiles assertions
  # ---------------------------------------------------------------------------

  # Test 5: Exactly one primary user must exist.
  test_exactly_one_primary_user = assert' (
    builtins.length primaryUserNames == 1
  ) "src/users/ registry must have exactly one primary user (isPrimary=true)";

  # Test 6: Primary user must have dscConfigFiles array declared.
  test_primary_user_has_dsc_config = assert' (
    let
      user = usersRegistry.${builtins.head primaryUserNames};
    in
    builtins.hasAttr "dscConfigFiles" user && user.dscConfigFiles or [ ] != [ ]
  ) "Primary user must have a non-empty dscConfigFiles array";

  # Test 7: Primary user must have all 7 user-level DSC files (bare filenames).
  test_primary_user_files_complete = assert' (
    let
      user = usersRegistry.${builtins.head primaryUserNames};
    in
    builtins.all (f: builtins.elem f (user.dscConfigFiles or [ ])) expectedUserDscFiles
  ) "Primary user's dscConfigFiles must include all 7 user-level DSC files";

  # Test 8: Primary user must not have system-level files in dscConfigFiles.
  test_primary_user_no_system_files = assert' (
    let
      user = usersRegistry.${builtins.head primaryUserNames};
    in
    !builtins.elem "system/scheduler.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/developer-mode.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/firewall.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/taskbar.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/computer-name.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/long-paths.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/storage-sense.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/font-substitutes.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/remote-desktop.dsc.yml" (user.dscConfigFiles or [ ])
    && !builtins.elem "system/packages.dsc.yml" (user.dscConfigFiles or [ ])
  ) "Primary user's dscConfigFiles must not contain system-level DSC files";

  # Test 9: Primary user files must be in alphabetical order.
  test_primary_user_files_alphabetical = assert' (
    let
      user = usersRegistry.${builtins.head primaryUserNames};
    in
    user.dscConfigFiles == builtins.sort builtins.lessThan user.dscConfigFiles
  ) "Primary user's dscConfigFiles must be sorted alphabetically";

  # ---------------------------------------------------------------------------
  # apply.ps1 per-user prefix and escape-prevention assertions
  # ---------------------------------------------------------------------------

  # Test 10: Per-user loop must prepend "user/" to dscConfigFiles entries.
  test_per_user_prepends_user_prefix = assert' (
    containsRegex ''resolvedConfigFile = "user/"'' windowsApplyText
    || containsRegex "resolvedConfigFile = .user/" windowsApplyText
    || containsRegex ''"user/\$userConfigFile"'' windowsApplyText
  ) "apply.ps1 per-user loop must prepend 'user/' to dscConfigFiles entries";

  # Test 11: Per-user loop must prevent path traversal (.. or / or \ in entries).
  test_per_user_escape_prevention = assert' (
    containsRegex ''match.*[\\/]'' windowsApplyText && containsRegex "path separators" windowsApplyText
  ) "apply.ps1 per-user loop must reject dscConfigFiles entries with path separators or '..'";
in
builtins.seq
  (builtins.deepSeq {
    inherit
      test_default_includes_system_files
      test_default_excludes_user_files
      test_param_doc_describes_per_user
      test_deduplication_mechanism
      test_exactly_one_primary_user
      test_primary_user_has_dsc_config
      test_primary_user_files_complete
      test_primary_user_no_system_files
      test_primary_user_files_alphabetical
      test_per_user_prepends_user_prefix
      test_per_user_escape_prevention
      ;
  })
  {
    success = true;
    testCount = 11;
    message = "All 11 DSC config file declaration tests passed";
  }
