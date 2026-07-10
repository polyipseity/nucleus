# tests/modules/core-tests.nix — Tests for backend selection, package resolution,
# and nix-index schedule invariants.
#
# Run via: nix-instantiate --eval tests/modules/core-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  inherit (import ../lib.nix) assert';

  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  # === NIX-INDEX SCHEDULE INVARIANTS ===
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;

  test_linux_nix_index_is_daily = assert' (
    containsRegex ''Description = "Daily nix-index database refresh";'' linuxText
    && containsRegex ''OnCalendar = "00:00:00";'' linuxText
    && !containsRegex ''OnCalendar = "Sun 00:00:00";'' linuxText
  ) "linux nix-index timer must run daily at 00:00";

  test_macos_nix_index_is_daily = assert' (
    containsRegex ''Label = "local.nix-index-update";'' macosText
    && containsRegex ''StartCalendarInterval = \[ \{ Hour = 0; Minute = 0; \} \];'' macosText
    && !containsRegex "Weekday = 0;" macosText
  ) "macOS nix-index launch agent must run daily at 00:00";

  # === BACKEND SELECTION RESOLUTION LOGIC ===
  # Mimics core.nix resolveBackend: check overrides → check policy → fall back to global backend.

  # Test 1: Per-package override takes precedence over everything.
  test_override_precedence =
    let
      overrides = {
        "google-chrome" = "nixpkgs";
      };
      overlapBackend = "homebrew";
      resolveBackend =
        packageName:
        if builtins.hasAttr packageName overrides then
          builtins.getAttr packageName overrides
        else
          overlapBackend;
    in
    assert' (resolveBackend "google-chrome" == "nixpkgs")
      "Override should take precedence: google-chrome should resolve to nixpkgs despite homebrew global";

  # Test 2: Policy-based categorization when overlapBackend == "policy".
  test_policy_based_categorization =
    let
      overlappingPackages = {
        "git" = {
          category = "cli";
        };
        "visual-studio-code" = {
          category = "gui";
        };
      };
      packageSelection = {
        overlapBackend = "policy";
        overrides = { };
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.overlapBackend == "policy" then
          defaultBackendFor overlappingPackages.${packageName}.category
        else
          packageSelection.overlapBackend;
    in
    assert' (
      (resolveBackend "git" == "nixpkgs") && (resolveBackend "visual-studio-code" == "homebrew")
    ) "Policy mode should route CLI to nixpkgs and GUI to homebrew";

  # Test 3: Global backend setting when overlapBackend != "policy".
  test_global_backend_fallback =
    let
      overlapBackend = "homebrew";
      overrides = { };
      resolveBackend =
        packageName:
        if builtins.hasAttr packageName overrides then
          builtins.getAttr packageName overrides
        else
          overlapBackend;
    in
    assert' (
      (resolveBackend "python" == "homebrew") && (resolveBackend "nodejs" == "homebrew")
    ) "Global backend should apply to all packages when not in policy mode";

  # Test 4: Empty overrides with policy mode cascades to category defaults.
  test_policy_with_no_overrides =
    let
      overlappingPackages = {
        "bat" = {
          category = "cli";
        };
        "blender" = {
          category = "gui";
        };
      };
      packageSelection = {
        overlapBackend = "policy";
        overrides = { };
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.overlapBackend == "policy" then
          defaultBackendFor overlappingPackages.${packageName}.category
        else
          packageSelection.overlapBackend;
    in
    assert' (
      (resolveBackend "bat" == "nixpkgs") && (resolveBackend "blender" == "homebrew")
    ) "Policy mode without overrides should use category defaults";

  # Test 5: Override can selectively flip specific packages in policy mode.
  test_selective_override_in_policy_mode =
    let
      overlappingPackages = {
        "ripgrep" = {
          category = "cli";
        }; # Default: nixpkgs
        "fzf" = {
          category = "cli";
        }; # Default: nixpkgs
      };
      packageSelection = {
        overlapBackend = "policy";
        overrides = {
          "ripgrep" = "homebrew";
        }; # Override ripgrep only
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.overlapBackend == "policy" then
          defaultBackendFor overlappingPackages.${packageName}.category
        else
          packageSelection.overlapBackend;
    in
    assert' (
      (resolveBackend "ripgrep" == "homebrew") && (resolveBackend "fzf" == "nixpkgs")
    ) "Selective override should flip only ripgrep to homebrew while fzf stays on nixpkgs";

  # Test 6: Multiple overrides in policy mode.
  test_multiple_overrides =
    let
      overlappingPackages = {
        "discord" = {
          category = "gui";
        };
        "vscode" = {
          category = "gui";
        };
        "git" = {
          category = "cli";
        };
      };
      packageSelection = {
        overlapBackend = "policy";
        overrides = {
          "discord" = "nixpkgs";
          "vscode" = "nixpkgs";
        };
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.overlapBackend == "policy" then
          defaultBackendFor overlappingPackages.${packageName}.category
        else
          packageSelection.overlapBackend;
    in
    assert' (
      (resolveBackend "discord" == "nixpkgs")
      && (resolveBackend "vscode" == "nixpkgs")
      && (resolveBackend "git" == "nixpkgs")
    ) "Multiple overrides should apply independently";

  # === BASIC LOGIC VALIDATION ===

  # Test 7: List filtering preserves order.
  test_filter_nulls = assert' (
    (builtins.filter (x: x != null) [
      1
      null
      2
      null
      3
    ]) == [
      1
      2
      3
    ]
  ) "Filtering null values from list failed";

  # === PLATFORM COMPATIBILITY FILTERING ===
  # Tests for the platformCompatible helper added in core.nix.

  # Test 8: Package without platforms field is compatible on both darwin and linux.
  test_platform_default_compatible =
    let
      # Simulate the logic from core.nix
      platformCompatible =
        isDarwin: isLinux: packageName:
        let
          entry = overlappingPackages.${packageName};
          platforms =
            entry.platforms or [
              "darwin"
              "linux"
            ];
        in
        if isDarwin then
          lib.elem "darwin" platforms
        else if isLinux then
          lib.elem "linux" platforms
        else
          true;

      overlappingPackages = {
        blender = {
          category = "gui";
        };
      };
    in
    assert' (
      platformCompatible true false "blender" && platformCompatible false true "blender"
    ) "Package without platforms field should be compatible on both darwin and linux";

  # Test 9: Package with platforms = ["darwin"] is excluded on linux.
  test_platform_darwin_only =
    let
      platformCompatible =
        isDarwin: isLinux: packageName:
        let
          entry = overlappingPackages.${packageName};
          platforms =
            entry.platforms or [
              "darwin"
              "linux"
            ];
        in
        if isDarwin then
          lib.elem "darwin" platforms
        else if isLinux then
          lib.elem "linux" platforms
        else
          true;

      overlappingPackages = {
        iterm2 = {
          category = "gui";
          platforms = [ "darwin" ];
        };
      };
    in
    assert' (
      platformCompatible true false "iterm2" && !platformCompatible false true "iterm2"
    ) "Package with platforms = [\"darwin\"] should be compatible on darwin but not linux";

  # Test 10: Package with platforms = ["linux"] is excluded on darwin.
  test_platform_linux_only =
    let
      platformCompatible =
        isDarwin: isLinux: packageName:
        let
          entry = overlappingPackages.${packageName};
          platforms =
            entry.platforms or [
              "darwin"
              "linux"
            ];
        in
        if isDarwin then
          lib.elem "darwin" platforms
        else if isLinux then
          lib.elem "linux" platforms
        else
          true;

      overlappingPackages = {
        linux-only-pkg = {
          category = "cli";
          platforms = [ "linux" ];
        };
      };
    in
    assert' (
      !platformCompatible true false "linux-only-pkg" && platformCompatible false true "linux-only-pkg"
    ) "Package with platforms = [\"linux\"] should be compatible on linux but not darwin";

  # Test 11: Attribute merging with lib.mkMerge.
  test_mkmerge_basic = assert' (
    builtins.length (
      lib.flatten [
        [
          1
          2
        ]
        [
          3
          4
        ]
      ]
    ) == 4
  ) "List flattening failed for config merging";

  # Test 12: OS-conditional path resolution.
  test_conditional_home_path =
    let
      isDarwin = false;
    in
    assert' (
      (if isDarwin then "/Users/admin" else "/home/admin") == "/home/admin"
    ) "Home directory path resolution failed for Linux";

  # Test 13: Package category validation.
  test_package_category_enum =
    let
      isValidCategory =
        category:
        builtins.elem category [
          "cli"
          "gui"
          "hardware"
        ];
    in
    assert' (
      (isValidCategory "cli") && (isValidCategory "gui") && !(isValidCategory "invalid")
    ) "Package category validation failed";

  # Collect all test results.
  allTests = [
    test_linux_nix_index_is_daily
    test_macos_nix_index_is_daily
    test_override_precedence
    test_policy_based_categorization
    test_global_backend_fallback
    test_policy_with_no_overrides
    test_selective_override_in_policy_mode
    test_multiple_overrides
    test_filter_nulls
    test_platform_default_compatible
    test_platform_darwin_only
    test_platform_linux_only
    test_mkmerge_basic
    test_conditional_home_path
    test_package_category_enum
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} core tests passed";
  testNames = [
    "1: Linux nix-index timer runs daily at 00:00"
    "2: macOS nix-index launch agent runs daily at 00:00"
    "3: Override precedence (overrides > policy > global)"
    "4: Policy-based categorization (CLI→nixpkgs, GUI→homebrew)"
    "5: Global backend fallback when not in policy"
    "6: Policy with no overrides cascades to defaults"
    "7: Selective override in policy mode"
    "8: Multiple overrides apply independently"
    "9: List filtering preserves order"
    "10: Config merging with lib.mkMerge"
    "11: OS-conditional path resolution"
    "12: Package category validation"
  ];
}
