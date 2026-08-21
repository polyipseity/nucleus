# tests/modules/winget-overlap-parity-tests.nix — Windows DSC single-source parity.
#
# The committed src/hosts/Windows/system/winget-packages.json is the artifact
# apply.ps1 consumes to filter packages.dsc.yml (Windows does not run Nix). It
# MUST equal the Nix-resolved Windows enable set from overlappingPackages in
# core.nix. Any divergence (hand-edited DSC, stale committed JSON) fails here —
# the dummy-proof guarantee that the Windows package set cannot contradict the
# shared overlap registry.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  # Replicate the flake `winget-packages` eval: evaluate core.nix standalone with
  # networking.hostName pinned to "Windows" and the NixOS/nix-darwin-only options
  # stubbed (assertions, networking.hostName).
  evaluated = lib.evalModules {
    prefix = [ ];
    modules = [
      ../../src/modules/core.nix
      {
        nucleus.macos.packageSelection.overlapBackend = "policy";
      }
      {
        options.assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
          internal = true;
        };
        options.networking.hostName = lib.mkOption {
          type = lib.types.str;
          default = "Windows";
          internal = true;
        };
      }
    ];
    specialArgs = {
      lib = lib;
      pkgs = import <nixpkgs> { system = "x86_64-linux"; };
      options = { };
    };
  };

  resolvedWindowsPackages = evaluated.config.nucleus.windows.generatedWinget.packages;

  # The committed artifact apply.ps1 reads.
  committedDoc = builtins.fromJSON (
    builtins.readFile ../../src/hosts/Windows/system/winget-packages.json
  );
  committedPackages = committedDoc.packages or [ ];

  test_resolved_matches_committed =
    assert' (resolvedWindowsPackages == committedPackages)
      "winget-packages.json must equal the Nix-resolved Windows enable set: resolved=${builtins.toString resolvedWindowsPackages} committed=${builtins.toString committedPackages}";

  # Cursor must be disabled on Windows (single source of truth: enable=false, no
  # per-host override enables it).
  test_cursor_disabled_on_windows = assert' (
    !builtins.elem "Anysphere.Cursor" resolvedWindowsPackages
  ) "Cursor must be disabled on Windows (overlappingPackages.cursor.enable=false)";

  # OBS Studio (stable) and JDK 25 must be enabled on Windows.
  test_obs_enabled_on_windows = assert' (builtins.elem "OBSProject.OBSStudio" resolvedWindowsPackages) "OBS Studio (stable) must be enabled on Windows";

  test_jdk_enabled_on_windows = assert' (builtins.elem "EclipseAdoptium.Temurin.25.JDK" resolvedWindowsPackages) "Temurin JDK 25 must be enabled on Windows";

  allTests = [
    test_resolved_matches_committed
    test_cursor_disabled_on_windows
    test_obs_enabled_on_windows
    test_jdk_enabled_on_windows
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} Windows overlap parity tests passed";
}
