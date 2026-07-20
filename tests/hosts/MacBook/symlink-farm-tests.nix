# symlink-farm tests.
#
# Verifies that the symlink farm script exists, is referenced in activation.nix,
# and that apple-sdk-tools.nix provides the farm tool subset.

let
  lib = import <nixpkgs/lib>;

  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  appleSdkToolsNix = builtins.readFile ../../../src/modules/lib/apple-sdk-tools.nix;
  symlinkFarmSh = builtins.readFile ../../../src/scripts/hosts/MacBook/macos-symlink-farm.sh;
in

# activation.nix references the symlink farm
assert lib.hasInfix "configureSymlinkFarm" activationNix;
assert lib.hasInfix "__nucleus_symlink_farm" activationNix;
assert lib.hasInfix "macos-symlink-farm.sh" activationNix;

# apple-sdk-tools.nix has symlinkFarmTools
assert lib.hasInfix "symlinkFarmTools" appleSdkToolsNix;

# Farm subset includes common tools
assert lib.hasInfix "python3 pip3" appleSdkToolsNix || lib.hasInfix "python3" appleSdkToolsNix;
assert lib.hasInfix "git" appleSdkToolsNix;

# Symlink farm script has expected structure
assert lib.hasInfix "FARM_DIR" symlinkFarmSh;
assert lib.hasInfix "FARM_MARKER" symlinkFarmSh;
assert lib.hasInfix "active_symlinks" symlinkFarmSh;
assert lib.hasInfix "_log" symlinkFarmSh;
assert lib.hasInfix "LOG_FILE" symlinkFarmSh;
assert lib.hasInfix "NUCLEUS_VERBOSE" symlinkFarmSh;
assert lib.hasInfix "active symlinks" symlinkFarmSh;

# Safety guarantees: only removes symlinks
assert lib.hasInfix "-L \"$link" symlinkFarmSh || lib.hasInfix "-L \"\\$link" symlinkFarmSh;

# References the Nix store path guard
assert lib.hasInfix "/nix/store/*" symlinkFarmSh;

{
  success = true;
  message = "symlink-farm tests passed";
}
