# tests/modules/nix-conf-warnings-tests.nix — nix.conf warnings regression guard.

let
  inherit (import ../lib.nix) flatten containsRegex;

  flakeText = builtins.readFile ../../src/flake.nix;
  cleaned = builtins.replaceStrings [ "`pkgs.nix`" ] [ "" ] flakeText;
in
assert containsRegex "check\\.sh.*nix\\.conf" flakeText;
assert containsRegex "test\\.sh.*nix\\.conf" flakeText;
assert containsRegex "cloud-setup\\.sh.*nix\\.conf" flakeText;
assert containsRegex "does not inject.*pkgs\\.nix" flakeText;
# pkgs.nixfmt (Nix formatter) is a legitimate dependency; pkgs.nix (Nix) is not.
# After removing all backtick-quoted `pkgs.nix` comment references, any remaining
# bare pkgs.nix not followed by a letter indicates a regression.
assert !containsRegex "pkgs\\.nix[^a-zA-Z]" cleaned;
{
  success = true;
  message = "nix-conf-warnings regression tests passed";
}
