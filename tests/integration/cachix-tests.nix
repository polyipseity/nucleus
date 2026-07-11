# tests/integration/cachix-tests.nix — Content assertions for nix-community
# cachix binary cache configuration in posix-base.nix.
#
# Run with: nix-instantiate --eval tests/integration/cachix-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

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
