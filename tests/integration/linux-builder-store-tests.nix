# tests/integration/linux-builder-store-tests.nix — Linux builder guest store dedup policy.

let
  inherit (import ../lib.nix) containsRegex;

  linuxBuilderText = builtins.readFile ../../src/hosts/MacBook/linux-builder.nix;
  nixCustomConfText = builtins.readFile ../../src/modules/configs/nix/nix.custom.conf;
in

assert containsRegex "environment\\.systemPackages" linuxBuilderText;
assert containsRegex "pkgs\\.jq" linuxBuilderText;
assert containsRegex "builders-use-substitutes = true" nixCustomConfText;
assert containsRegex "darwin\\.linux-builder\\.override" linuxBuilderText;
assert containsRegex "nix-community\\.cachix\\.org" linuxBuilderText;
assert containsRegex "nix\\.gc" linuxBuilderText;
assert containsRegex "auto-optimise-store = true" linuxBuilderText;

{
  success = true;
  message = "Linux builder store deduplication policy assertions passed";
}
