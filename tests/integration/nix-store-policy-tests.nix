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
assert containsRegex "lazy-trees = true" posixBaseText;
assert containsRegex "eval-cores = 0" posixBaseText;
assert containsRegex "lazy-trees = true" nixCustomConfText;
assert containsRegex "eval-cores = 0" nixCustomConfText;
assert containsRegex "min-free = 42949672960" nixCustomConfText;
assert containsRegex "max-free = 103079215104" nixCustomConfText;
assert containsRegex "min-free = 40 \\* 1024" posixBaseText;
assert containsRegex "max-free = 96 \\* 1024" posixBaseText;

{
  success = true;
  message = "Nix store policy content assertions passed";
}
