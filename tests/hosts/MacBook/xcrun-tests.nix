# xcrun-free compiler resolution regression tests.
#
# Bare-format compiler names (CC = "clang") caused the xcrun dialog on macOS
# when subprocesses resolved names outside a Nix build environment.

let
  lib = import <nixpkgs/lib>;

  envNix = builtins.readFile ../../../src/modules/lib/env-catalog.nix;
  shellNix = builtins.readFile ../../../src/modules/shell.nix;
  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  ntfs3gText = builtins.readFile ../../../src/hosts/MacBook/ntfs-3g.nix;
  appleSdkToolsNix = builtins.readFile ../../../src/modules/lib/apple-sdk-tools.nix;
  appleSdkEnhancedNix = builtins.readFile ../../../src/modules/lib/apple-sdk-enhanced.nix;
  symlinkFarmSh = builtins.readFile ../../../src/scripts/hosts/MacBook/macos-symlink-farm.sh;
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
# DEVELOPER_DIR/SDKROOT now point at appleSdkEnhanced (not bare pkgs.apple-sdk)
assert lib.hasInfix "appleSdkEnhanced" envNix;
assert lib.hasInfix "MacOSX.sdk" envNix;
assert lib.hasInfix "direnvrc" shellNix;
assert lib.hasInfix "print-dev-env" shellNix;

# activation.nix
assert lib.hasInfix "xcode-select --switch" activationNix;
assert lib.hasInfix "appleSdkEnhanced" activationNix;
assert lib.hasInfix "configureSymlinkFarm" activationNix;

# apple-sdk-tools.nix
assert lib.hasInfix "python3" appleSdkToolsNix;
assert lib.hasInfix "allTools" appleSdkToolsNix;
assert lib.hasInfix "symlinkFarmTools" appleSdkToolsNix;

# apple-sdk-enhanced.nix
assert lib.hasInfix "symlinkJoin" appleSdkEnhancedNix;
assert lib.hasInfix "apple-sdk-tools" appleSdkEnhancedNix;

# macos-symlink-farm.sh
assert lib.hasInfix "symlink-farm" symlinkFarmSh;
assert lib.hasInfix "FARM_DIR" symlinkFarmSh;
assert lib.hasInfix "FARM_MARKER" symlinkFarmSh;
assert lib.hasInfix "active_symlinks" symlinkFarmSh;

# ntfs-3g.nix
assert lib.hasInfix "llvmPackages.clang" ntfs3gText;
assert lib.hasInfix ''export CC="'' ntfs3gText;
assert lib.hasInfix ''export CXX="'' ntfs3gText;

{
  success = true;
  message = "xcrun-free compiler resolution tests passed";
}
