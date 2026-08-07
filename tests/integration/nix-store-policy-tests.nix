# tests/integration/nix-store-policy-tests.nix — Store optimise policy across hosts.

let
  inherit (import ../lib.nix) containsRegex;

  posixBaseText = builtins.readFile ../../src/modules/posix-base.nix;
  nixCustomConfText = builtins.readFile ../../src/modules/configs/nix/nix.custom.conf;
in

assert containsRegex "auto-optimise-store = true" posixBaseText;
assert containsRegex "keep-derivations = true" posixBaseText;
assert containsRegex "keep-outputs = true" posixBaseText;
assert containsRegex "nix\\.optimise" posixBaseText;
assert containsRegex "nixStoreOptimise" posixBaseText;
assert containsRegex "auto-optimise-store = true" nixCustomConfText;
assert containsRegex "keep-derivations = true" nixCustomConfText;
assert containsRegex "keep-outputs = true" nixCustomConfText;

{
  success = true;
  message = "Nix store policy content assertions passed";
}
