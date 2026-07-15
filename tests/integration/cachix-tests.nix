# tests/integration/cachix-tests.nix — Content assertions for nix-community cachix configuration.

let
  inherit (import ../lib.nix) containsRegex flatten;

  posixBaseText = builtins.readFile ../../src/modules/posix-base.nix;
in

# nix-community cachix cache configuration
assert containsRegex "nix-community\\.cachix\\.org" posixBaseText;
assert containsRegex "extra-substituters" posixBaseText;
assert containsRegex "extra-trusted-public-keys" posixBaseText;
assert containsRegex "mB9FSh9qf2dCimDSUo8Zy7bkq5CX" posixBaseText;

{
  success = true;
  message = "Cachix configuration content assertions passed";
}
