# Regression tests for the ntfs-3g source build on MacBook.
#
# WHY: the Aug 20 build failed because the nix clang-wrapper's
#   darwin-sdk-setup.bash overrides SDKROOT from DEVELOPER_DIR_arm64_apple_darwin
#   (already set via xcode-select --switch) and emits
#   "Multiple conflicting values defined for DEVELOPER_DIR_arm64_apple_darwin" →
#   "unable to find sdk: 'macosx'".  With no SDK, every link test fails and
#   configure aborts with "Unable to find libdl".  These assertions pin the fix
#   in place: the build script must export DEVELOPER_DIR_arm64_apple_darwin to
#   the enhanced SDK root and unset DEVELOPER_DIR, and must pin CFLAGS/CXXFLAGS
#   to gnu17 as defense-in-depth.  ntfs-3g.nix must thread sdkDevDir/cFlags/
#   cxxFlags through to the script.

let
  lib = import <nixpkgs/lib>;

  buildScript = builtins.readFile ../../../src/hosts/MacBook/scripts/macos-build-ntfs3g.sh;
  ntfs3gNix = builtins.readFile ../../../src/hosts/MacBook/ntfs-3g.nix;
in

# Build script must resolve the SDK via DEVELOPER_DIR_arm64_apple_darwin.
assert lib.hasInfix "export DEVELOPER_DIR_arm64_apple_darwin=" buildScript;
assert lib.hasInfix "unset DEVELOPER_DIR" buildScript;
# CFLAGS/CXXFLAGS must be exported (gnu17 pin, defense-in-depth). The literal
# "-std=gnu17" lives in ntfs-3g.nix and is passed as the C_FLAGS/CXX_FLAGS args;
# the script must export them into CFLAGS/CXXFLAGS for ./configure and make.
assert lib.hasInfix "export CC CXX CPPFLAGS CFLAGS=" buildScript;
assert lib.hasInfix "CXXFLAGS=" buildScript;
assert lib.hasInfix "C_FLAGS=" buildScript;
assert lib.hasInfix "CXX_FLAGS=" buildScript;
# Script must accept the new positional args (16 total).
assert lib.hasInfix "SDK_DEV_DIR=" buildScript;
# Build tools path must be PREPENDED so nix gnumake shadows BSD /usr/bin/make.
# Appending it (PATH="$PATH:$BUILD_TOOLS_PATH") made BSD make win, aborting the
# build with "Something went wrong bootstrapping makefile fragments".
assert lib.hasInfix "export PATH=\"$BUILD_TOOLS_PATH:$PATH\"" buildScript;

# ntfs-3g.nix must define and thread the new params.
assert lib.hasInfix "sdkDevDir = appleSdkEnhanced" ntfs3gNix;
assert lib.hasInfix "cFlags = \"-std=gnu17\"" ntfs3gNix;
assert lib.hasInfix "cxxFlags = \"-std=gnu17\"" ntfs3gNix;
assert lib.hasInfix "sdkDevDir" ntfs3gNix;

{
  success = true;
  message = "ntfs-3g build SDK/CFLAGS pin tests passed";
}
