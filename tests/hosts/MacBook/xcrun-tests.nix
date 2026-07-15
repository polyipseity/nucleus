# xcrun-free compiler resolution regression tests.
#
# Bare-format compiler names (CC = "clang") caused the xcrun dialog on macOS
# when subprocesses resolved names outside a Nix build environment.

let
  lib = import <nixpkgs/lib>;

  envNix = builtins.readFile ../../../src/modules/lib/env-vars.nix;
  shellNix = builtins.readFile ../../../src/modules/shell.nix;
  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  ntfs3gText = builtins.readFile ../../../src/hosts/MacBook/ntfs-3g.nix;
in

# shell/env.nix
assert lib.hasInfix "/bin/clang" envNix;
assert lib.hasInfix "/bin/clang++" envNix;
assert lib.hasInfix "/bin/ld.lld" envNix;
assert lib.hasInfix "OPENCODE_DISABLE_AUTOUPDATE" envNix;
assert !lib.hasInfix ''CC = "clang";'' envNix;

# shell.nix
assert lib.hasInfix "DEVELOPER_DIR" shellNix;
assert lib.hasInfix "SDKROOT" shellNix;
# apple-sdk values are now defined in the centralized env var catalog
assert lib.hasInfix "pkgs.apple-sdk" envNix;
assert lib.hasInfix "MacOSX.sdk" envNix;
assert lib.hasInfix "direnvrc" shellNix;
assert lib.hasInfix "print-dev-env" shellNix;

# activation.nix
assert lib.hasInfix "xcode-select --switch" activationNix;
assert lib.hasInfix "apple-sdk" activationNix;

# ntfs-3g.nix
assert lib.hasInfix "llvmPackages.clang" ntfs3gText;
assert lib.hasInfix ''export CC="'' ntfs3gText;
assert lib.hasInfix ''export CXX="'' ntfs3gText;

{
  success = true;
  message = "xcrun-free compiler resolution tests passed";
}
