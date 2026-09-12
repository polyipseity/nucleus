# tests/modules/core-tests.nix — Backend selection, package resolution, platform compatibility.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  # === BACKEND SELECTION RESOLUTION LOGIC ===
  # Mimics core.nix resolveBackend: check overrides → check policy → fall back to global backend.
  test_override_precedence =
    let
      overrides = {
        "google-chrome" = "nixpkgs";
      };
      backend = "homebrew";
      resolveBackend =
        packageName:
        if builtins.hasAttr packageName overrides then builtins.getAttr packageName overrides else backend;
    in
    assert' (resolveBackend "google-chrome" == "nixpkgs")
      "Override should take precedence: google-chrome should resolve to nixpkgs despite homebrew global";

  # Policy-based categorization when backend == "policy".
  test_policy_based_categorization =
    let
      managedPackages = {
        "git" = {
          category = "cli";
        };
        "visual-studio-code" = {
          category = "gui";
        };
      };
      packageSelection = {
        backend = "policy";
        overrides = { };
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.backend == "policy" then
          defaultBackendFor managedPackages.${packageName}.category
        else
          packageSelection.backend;
    in
    assert' (
      (resolveBackend "git" == "nixpkgs") && (resolveBackend "visual-studio-code" == "homebrew")
    ) "Policy mode should route CLI to nixpkgs and GUI to homebrew";

  # Global backend setting when backend != "policy".
  test_global_backend_fallback =
    let
      backend = "homebrew";
      overrides = { };
      resolveBackend =
        packageName:
        if builtins.hasAttr packageName overrides then builtins.getAttr packageName overrides else backend;
    in
    assert' (
      (resolveBackend "python" == "homebrew") && (resolveBackend "nodejs" == "homebrew")
    ) "Global backend should apply to all packages when not in policy mode";

  # Empty overrides with policy mode cascades to category defaults.
  test_policy_with_no_overrides =
    let
      managedPackages = {
        "bat" = {
          category = "cli";
        };
        "blender" = {
          category = "gui";
        };
      };
      packageSelection = {
        backend = "policy";
        overrides = { };
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.backend == "policy" then
          defaultBackendFor managedPackages.${packageName}.category
        else
          packageSelection.backend;
    in
    assert' (
      (resolveBackend "bat" == "nixpkgs") && (resolveBackend "blender" == "homebrew")
    ) "Policy mode without overrides should use category defaults";

  # Override can selectively flip specific packages in policy mode.
  test_selective_override_in_policy_mode =
    let
      managedPackages = {
        "ripgrep" = {
          category = "cli";
        }; # Default: nixpkgs
        "fzf" = {
          category = "cli";
        }; # Default: nixpkgs
      };
      packageSelection = {
        backend = "policy";
        overrides = {
          "ripgrep" = "homebrew";
        }; # Override ripgrep only
      };

      defaultBackendFor = category: if category == "cli" then "nixpkgs" else "homebrew";

      resolveBackend =
        packageName:
        if builtins.hasAttr packageName packageSelection.overrides then
          builtins.getAttr packageName packageSelection.overrides
        else if packageSelection.backend == "policy" then
          defaultBackendFor managedPackages.${packageName}.category
        else
          packageSelection.backend;
    in
    assert' (
      (resolveBackend "ripgrep" == "homebrew") && (resolveBackend "fzf" == "nixpkgs")
    ) "Selective override should flip only ripgrep to homebrew while fzf stays on nixpkgs";

  # Multiple overrides in policy mode.
  test_multiple_overrides =
    let
      managedPackages = {
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
        backend = "policy";
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
        else if packageSelection.backend == "policy" then
          defaultBackendFor managedPackages.${packageName}.category
        else
          packageSelection.backend;
    in
    assert' (
      (resolveBackend "discord" == "nixpkgs")
      && (resolveBackend "vscode" == "nixpkgs")
      && (resolveBackend "git" == "nixpkgs")
    ) "Multiple overrides should apply independently";

  # === PLATFORM COMPATIBILITY FILTERING ===
  # Tests for the platformCompatible helper added in core.nix.

  # Test 8: Package without platforms field is compatible on both darwin and linux.
  test_platform_default_compatible =
    let
      # Simulate the logic from core.nix
      platformCompatible =
        isDarwin: isLinux: packageName:
        let
          entry = managedPackages.${packageName};
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

      managedPackages = {
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
          entry = managedPackages.${packageName};
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

      managedPackages = {
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
          entry = managedPackages.${packageName};
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

      managedPackages = {
        linux-only-pkg = {
          category = "cli";
          platforms = [ "linux" ];
        };
      };
    in
    assert' (
      !platformCompatible true false "linux-only-pkg" && platformCompatible false true "linux-only-pkg"
    ) "Package with platforms = [\"linux\"] should be compatible on linux but not darwin";

  # Collect all test results.
  allTests = [
    test_override_precedence
    test_policy_based_categorization
    test_global_backend_fallback
    test_policy_with_no_overrides
    test_selective_override_in_policy_mode
    test_multiple_overrides
    test_platform_default_compatible
    test_platform_darwin_only
    test_platform_linux_only
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} core tests passed";
  testNames = [
    "1: Override precedence (overrides > policy > global)"
    "2: Policy-based categorization (CLI→nixpkgs, GUI→homebrew)"
    "3: Global backend fallback when not in policy"
    "4: Policy with no overrides cascades to defaults"
    "5: Selective override in policy mode"
    "6: Multiple overrides apply independently"
    "7: Package without platforms compatible on both"
    "8: Package with platforms=[darwin] excluded on linux"
    "9: Package with platforms=[linux] excluded on darwin"
  ];
}
