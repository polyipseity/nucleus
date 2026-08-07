# tests/integration/gc-options-tests.nix — Content assertions for GC option defaults.

let
  inherit (import ../lib.nix) containsRegex;

  gcOptionsText = builtins.readFile ../../src/modules/lib/gc-options.nix;
in

assert containsRegex "generationsKeep = lib.mkOption" gcOptionsText;
assert containsRegex "default = 7;" gcOptionsText;
assert containsRegex "systemGenerationsKeep = lib.mkOption" gcOptionsText;
assert containsRegex "default = config.modules.gc.generationsKeep;" gcOptionsText;
assert containsRegex "defaultText = lib.literalExpression \"config.modules.gc.generationsKeep\";"
  gcOptionsText;
assert containsRegex "hmGenerationsKeep = lib.mkOption" gcOptionsText;
assert containsRegex "nixStoreExpiry = lib.mkOption" gcOptionsText;
assert containsRegex "defaultText = lib.literalExpression \"config.modules.gc.expiry\";"
  gcOptionsText;

{
  success = true;
  message = "GC options content assertions passed";
}
