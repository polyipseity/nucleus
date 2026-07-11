# tests/hosts/MacBook/betterdisplay-settings-tests.nix — Verify BetterDisplay settings wiring on macOS.
#
# This suite guards declarative BetterDisplay defaults and activation hooks so
# menu icon visibility stays converged after app updates and rebuilds.
# BetterDisplay is macOS-only; NixOS and Windows have no equivalent domain.

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
