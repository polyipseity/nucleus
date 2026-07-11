# tests/hosts/MacBook/homebrew-tests.nix — Homebrew configuration content assertions.
#
# Verifies that homebrew.nix declares the expected trust entries for third-party
# taps and formulae (nix-homebrew integration), and that the module structure is
# preserved.

let
  lib = import <nixpkgs/lib>;
  homebrewText = builtins.readFile ../../../src/hosts/MacBook/homebrew.nix;
in

# nix-homebrew trust configuration
assert lib.hasInfix ''taps = [ "cirruslabs/cli" ];'' homebrewText;
assert lib.hasInfix ''"smudge/smudge/nightlight"'' homebrewText;
assert lib.hasInfix ''"zackelia/formulae/bclm"'' homebrewText;

{
  success = true;
  message = "Homebrew configuration content tests passed";
}
