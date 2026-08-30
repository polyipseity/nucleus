# tests/modules/obs-virtual-camera-tests.nix — NixOS OBS virtual camera wiring invariant.
#
# Source-text assertion (NOT a full NixOS eval): confirms the NixOS desktop
# config enables the OBS virtual camera backend without pulling in a second
# (wrapped) OBS install.  Run with: nix-instantiate --eval tests/modules/obs-virtual-camera-tests.nix

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  desktopText = builtins.readFile ../../src/hosts/NixOS/desktop.nix;

  test_obs_virtual_camera_enabled = assert' (
    lib.hasInfix "programs.obs-studio.enableVirtualCamera = true;" desktopText
  ) "NixOS desktop.nix must enable programs.obs-studio.enableVirtualCamera";

  test_obs_package_null_avoid_duplicate_install = assert' (
    lib.hasInfix "programs.obs-studio.package = null;" desktopText
  ) "NixOS desktop.nix must set programs.obs-studio.package = null to avoid a duplicate OBS install";

  test_obs_enable_set = assert' (
    lib.hasInfix "programs.obs-studio.enable = true;" desktopText
  ) "NixOS desktop.nix must set programs.obs-studio.enable = true";

  allTests = [
    test_obs_enable_set
    test_obs_package_null_avoid_duplicate_install
    test_obs_virtual_camera_enabled
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} OBS virtual camera tests passed";
  testNames = [
    "1: NixOS desktop.nix sets programs.obs-studio.enable = true"
    "2: NixOS desktop.nix sets programs.obs-studio.package = null (no duplicate OBS)"
    "3: NixOS desktop.nix enables programs.obs-studio.enableVirtualCamera"
  ];
}
