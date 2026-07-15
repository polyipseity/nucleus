# BetterDisplay defaults wiring tests.

let
  lib = import <nixpkgs/lib>;
  defaultsText = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
in
assert lib.hasInfix ''"pro.betterdisplay.BetterDisplay"'' defaultsText;
assert lib.hasInfix "hideMenuIcon = true;" defaultsText;
assert lib.hasInfix "showInMenuBar = false;" defaultsText;

{
  success = true;
  message = "BetterDisplay defaults wiring tests passed";
}
