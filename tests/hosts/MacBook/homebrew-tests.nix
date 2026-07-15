# Homebrew configuration content tests.

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
