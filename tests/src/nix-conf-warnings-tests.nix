# tests/src/nix-conf-warnings-tests.nix — Regression guard for nix.conf warnings.
#
# Validates that mkCheckApp, mkTestApp, and mkCloudSetupApp intentionally omit
# pkgs.nix from runtimeInputs, so scripts use the host Nix (Determinate Nix on
# this repo) rather than nixpkgs' vanilla Nix. Vanilla Nix emits
#   warning: unknown setting 'eval-cores'
#   warning: unknown setting 'lazy-trees'
# when reading /etc/nix/nix.conf.
#
# Follows the pattern established by mkUpdateApp's documented omission.
# Any new app that also omits pkgs.nix should be added here with a matching
# comment in flake.nix.
#
# Run with: nix-instantiate --eval tests/src/nix-conf-warnings-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

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
true
