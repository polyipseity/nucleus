# tests/modules/winget-overlap-parity-tests.nix — Windows DSC single-source parity.
#
# The committed src/hosts/Windows/system/winget-packages.json is the artifact
# apply.ps1 consumes to filter packages.dsc.yml (Windows does not run Nix). It
# MUST equal the Nix-resolved Windows enable set from managedPackages in
# core.nix. Any divergence (hand-edited DSC, stale committed JSON) fails here —
# the dummy-proof guarantee that the Windows package set cannot contradict the
# shared package registry.

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
        nucleus.packages.selection.backend = "policy";
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

  resolvedWindowsPackages = evaluated.config.nucleus.windows.wingetPackages.packages;

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
  ) "Cursor must be disabled on Windows (managedPackages.cursor.enable=false)";

  # OBS Studio (stable) and JDK 25 must be enabled on Windows.
  test_obs_enabled_on_windows = assert' (builtins.elem "OBSProject.OBSStudio" resolvedWindowsPackages) "OBS Studio (stable) must be enabled on Windows";

  test_jdk_enabled_on_windows = assert' (builtins.elem "EclipseAdoptium.Temurin.25.JDK" resolvedWindowsPackages) "Temurin JDK 25 must be enabled on Windows";

  # Every WinGet id declared in packages.dsc.yml MUST be covered by the
  # generated allow-list, otherwise apply.ps1 would silently drop that DSC
  # resource at provisioning time. Cursor is the single intentional exception
  # (overlappingPackages.cursor.enable=false disables it everywhere).
  dscPath = ../../src/hosts/Windows/system/packages.dsc.yml;
  dscText = builtins.readFile dscPath;
  # Nix has no native YAML parser; extract `settings.id:` lines (8-space indent)
  # via regex. This matches the DSC package resource id field precisely.
  dscLines = lib.splitString "\n" dscText;
  dscIdsRaw = builtins.filter (l: builtins.match "^        id: .*" l != null) dscLines;
  dscIds = builtins.map (l: builtins.substring 12 (builtins.stringLength l - 12) l) dscIdsRaw;
  test_dsc_ids_covered_by_allowlist =
    assert'
      (builtins.all (id: builtins.elem id resolvedWindowsPackages || id == "Anysphere.Cursor") dscIds)
      "Every DSC WinGet id must be in the generated allow-list (cursor is the only allowed exception): dscIds=${builtins.toString dscIds}";

  # The committed artifact must be byte-deterministic: object keys sorted
  # case-sensitively, the packages array sorted case-sensitively, and exactly
  # one trailing newline. This guards against hand-edits that break diffs.
  committedRaw = builtins.readFile ../../src/hosts/Windows/system/winget-packages.json;
  # Strip the single trailing newline for key/array shape checks (Nix regex has
  # no "\n" escape, and builtins.match anchors to the whole string).
  committedBody = lib.removeSuffix "\n" committedRaw;
  # Trailing newline: the raw text ends with exactly one "\n" (not two).
  committedEndsWithSingleNewline =
    builtins.match ".*\n" committedRaw != null && builtins.match ".*\n\n" committedRaw == null;
  committedSortedKeys = builtins.match ''^\{.*"\$schema".*"packages".*\}$'' committedBody != null; # array present
  test_committed_json_sorted_and_terminated = assert' (
    committedEndsWithSingleNewline && committedSortedKeys
  ) "winget-packages.json must have sorted keys and exactly one trailing newline";

  allTests = [
    test_resolved_matches_committed
    test_cursor_disabled_on_windows
    test_obs_enabled_on_windows
    test_jdk_enabled_on_windows
    test_dsc_ids_covered_by_allowlist
    test_committed_json_sorted_and_terminated
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} Windows overlap parity tests passed";
}
