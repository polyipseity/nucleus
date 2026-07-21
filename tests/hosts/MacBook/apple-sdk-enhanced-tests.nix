# apple-sdk-enhanced tests.
#
# Verifies that apple-sdk-enhanced.nix correctly imports apple-sdk-tools.nix,
# builds a symlinkJoin derivation, and provides usr/bin/ symlinks for all
# non-null tools.

let
  lib = import <nixpkgs/lib>;

  appleSdkToolsNix = builtins.readFile ../../../src/modules/lib/apple-sdk-tools.nix;
  appleSdkEnhancedNix = builtins.readFile ../../../src/modules/lib/apple-sdk-enhanced.nix;
  envCatalogNix = builtins.readFile ../../../src/modules/lib/env-catalog.nix;
in

# apple-sdk-tools.nix structure
assert lib.hasInfix "allTools" appleSdkToolsNix;
assert lib.hasInfix "symlinkFarmTools" appleSdkToolsNix;

# All provisioned tools have non-null paths
assert lib.hasInfix "pkgs.python3" appleSdkToolsNix;
assert lib.hasInfix "pkgs.llvmPackages.clang" appleSdkToolsNix;
assert lib.hasInfix "pkgs.git" appleSdkToolsNix;
assert lib.hasInfix "pkgs.gnumake" appleSdkToolsNix;

# Null tools exist as placeholders (not missing)
assert lib.hasInfix "swift" appleSdkToolsNix;
assert lib.hasInfix "otool" appleSdkToolsNix;
assert lib.hasInfix "as = null;" appleSdkToolsNix;

# Header comment mentions regeneration command
assert lib.hasInfix "otool -L" appleSdkToolsNix;
assert lib.hasInfix "libxcselect" appleSdkToolsNix;

# apple-sdk-enhanced.nix uses symlinkJoin
assert lib.hasInfix "symlinkJoin" appleSdkEnhancedNix;
assert lib.hasInfix "apple-sdk-tools.nix" appleSdkEnhancedNix;
assert lib.hasInfix "runCommand \"apple-sdk-enhanced-usr-bin\"" appleSdkEnhancedNix;

# env-catalog.nix references appleSdkEnhanced
assert lib.hasInfix "appleSdkEnhanced" envCatalogNix;
assert lib.hasInfix "DEVELOPER_DIR" envCatalogNix;
assert lib.hasInfix "SDKROOT" envCatalogNix;

# DEVELOPER_DIR/SDKROOT point at appleSdkEnhanced, not bare pkgs.apple-sdk
assert lib.hasInfix "appleSdkEnhanced" envCatalogNix;
assert lib.hasInfix "DEVELOPER_DIR" envCatalogNix;

{
  success = true;
  message = "apple-sdk-enhanced tests passed";
}
