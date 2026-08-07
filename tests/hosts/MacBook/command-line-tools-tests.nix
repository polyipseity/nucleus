# Static assertions for Apple CLT install-tree removal during MacBook activation.

let
  lib = import <nixpkgs/lib>;

  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  cltScriptSh = builtins.readFile ../../../src/scripts/hosts/MacBook/macos-remove-command-line-tools.sh;
  beforeXcodeSelect = lib.elemAt (lib.splitString "configure-xcode-select" activationNix) 0;
in

assert lib.hasInfix "macos-remove-command-line-tools.sh" activationNix;
assert lib.hasInfix "remove-command-line-tools" beforeXcodeSelect;
assert lib.hasInfix "command-line-tools.log" activationNix;

assert lib.hasInfix "CommandLineTools" cltScriptSh;
assert lib.hasInfix "rm -rf" cltScriptSh;
assert lib.hasInfix "command-line-tools:" cltScriptSh;
assert !lib.hasInfix "pkgutil --forget" cltScriptSh;
assert !lib.hasInfix "/Applications/Xcode" cltScriptSh;
assert !lib.hasInfix "rm -rf /Library/Developer" cltScriptSh;

{
  success = true;
  message = "command-line-tools removal tests passed";
}
