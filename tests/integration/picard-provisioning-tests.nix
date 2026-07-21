let
  coreText = builtins.readFile ../../src/modules/core.nix;
  nixosDesktopText = builtins.readFile ../../src/hosts/NixOS/desktop.nix;
  windowsSystemPackagesText = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;

  inherit (import ../lib.nix) assert' containsRegex flatten;

  test_macos_routes_picard_to_homebrew = assert' (
    containsRegex ''"musicbrainz-picard" = \{'' coreText
    && containsRegex ''name = "musicbrainz-picard"'' coreText
    && containsRegex ''nixpkgsAttr = "picard"'' coreText
  ) "core.nix must route musicbrainz-picard via overlap policy with nixpkgs picard fallback";

  test_nixos_installs_picard = assert' (containsRegex ''\bpicard\b'' nixosDesktopText) "NixOS desktop package list must include picard";

  test_windows_installs_picard = assert' (containsRegex ''id: MusicBrainz\.Picard'' windowsSystemPackagesText) "Windows system/packages.dsc.yml must install MusicBrainz.Picard";

  allTests = [
    test_macos_routes_picard_to_homebrew
    test_nixos_installs_picard
    test_windows_installs_picard
  ];
in
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Picard package provisioning tests passed";
}
