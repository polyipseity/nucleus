# MacBook/ntfs-3g.nix — build polyipseity/ext.ntfs-3g from source.
#
# WHY: build from source, not nixpkgs:
#   The polyipseity fork of ntfs-3g (commit f0e5cb0) links against fuse-t, a
#   FSKit-based FUSE implementation distributed as a Homebrew cask at
#   /usr/local/lib/libfuse-t.dylib.  Nix sandbox builds cannot resolve this
#   impure dependency, so we build imperatively during activation.
#
# WHY: activation script vs Nix derivation:
#   A pure Nix derivation would require fuse-t headers and dylib inside the
#   sandbox — impractical when fuse-t is a Homebrew cask placed in a fixed
#   system path.  The activation script runs after Homebrew, guaranteeing
#   fuse-t is installed before we build ntfs-3g.
#
# WHY: not ntfs-3g from nixpkgs:
#   nixpkgs ntfs-3g uses the native macOS FUSE kext (osxfuse / macFUSE), which
#   requires a kernel extension.  fuse-t is a modern FSKit-based alternative
#   that works without kext approval, so the polyipseity fork is the preferred
#   build on modern macOS.
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
  appleSdkEnhanced = import ../../modules/lib/apple-sdk-enhanced.nix { inherit pkgs lib; };
  sdkRoot = "${appleSdkEnhanced}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
  # WHY: the nix clang-wrapper's darwin-sdk-setup.bash overrides SDKROOT from
  #   DEVELOPER_DIR_arm64_apple_darwin (already set in the activation env via
  #   xcode-select --switch) or a hardcoded apple-sdk-14.4 fallback, ignoring
  #   the SDKROOT we export.  Pointing DEVELOPER_DIR_arm64_apple_darwin at the
  #   enhanced SDK root makes the wrapper resolve the correct SDK instead of
  #   erroring with "unable to find sdk: 'macosx'".
  sdkDevDir = appleSdkEnhanced;
  # Pinned source for the polyipseity/ext.ntfs-3g fork (edge branch).
  ntfs3gSrc = pkgs.fetchFromGitHub {
    owner = "polyipseity";
    repo = "ext.ntfs-3g";
    rev = "f0e5cb0274e30334dd03aefb4fd5a14c239e6756";
    hash = "sha256-35c5H2q1/YsKiyFXC/nd5Ax3fngpcGL0J1TkX2Vk+5M=";
  };

  # Build tools referenced by nix store path so they resolve during activation.
  buildToolsPath = lib.makeBinPath (
    with pkgs;
    [
      autoconf
      automake
      gnumake
      libtool
      llvmPackages.clang
      pkg-config
    ]
  );

  # aclocal needs Nix-installed m4 macros (libtool.m4 from libtool, pkg.m4 from pkg-config).
  aclocalPath = lib.concatStringsSep ":" [
    "${pkgs.libtool}/share/aclocal"
    "${pkgs.pkg-config}/share/aclocal"
  ];

  cryptoPatchPath = ./patches/ntfs-3g-crypto.patch;
  rootbindirPatchPath = ./patches/ntfs-3g-rootbindir.patch;
  installHookPatchPath = ./patches/ntfs-3g-install-hook.patch;

  # Build parameters (extracted for fingerprint-based rebuild detection).
  cppFlags = "-I/usr/local/include/fuse/fuse";
  # fuse-t is linked only during make/install — not during ./configure, where
  # -lfuse-t in LDFLAGS breaks autoconf link probes under nix clang wrappers.
  linkFlags = "-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib";
  configureFlags = "--with-fuse=external --prefix=/usr/local --disable-crypto --disable-plugins";
  clangBin = "${pkgs.llvmPackages.clang}/bin/clang";
  clangxxBin = "${pkgs.llvmPackages.clang}/bin/clang++";
  # WHY: pin the C standard to gnu17, not the autoconf-detected gnu23.
  #   clang 21 defaults to -std=gnu23, under which calling an undeclared
  #   function is a hard error.  autoconf's AC_CHECK_FUNC probes rely on
  #   implicit declarations (no headers), so every probe fails and configure
  #   aborts with "Unable to find libdl".  gnu17 downgrades that to a warning.
  cFlags = "-std=gnu17";
  cxxFlags = "-std=gnu17";
  buildFingerprint = builtins.hashString "sha256" (
    builtins.concatStringsSep "\n" [
      ntfs3gSrc.outPath
      buildToolsPath
      aclocalPath
      clangBin
      clangxxBin
      cppFlags
      linkFlags
      configureFlags
      sdkRoot
      cFlags
      cxxFlags
      sdkDevDir
      cryptoPatchPath
      rootbindirPatchPath
      installHookPatchPath
    ]
  );
in
{
  system.activationScripts.postActivation.text = lib.mkBefore ''
    "${activationBundle}/src/hosts/MacBook/scripts/macos-build-ntfs3g.sh" \
      "${buildFingerprint}" \
      "${buildToolsPath}" \
      "${aclocalPath}" \
      "${ntfs3gSrc}" \
      "${clangBin}" \
      "${clangxxBin}" \
      "${cppFlags}" \
      "${linkFlags}" \
      "${configureFlags}" \
      "${cryptoPatchPath}" \
      "${rootbindirPatchPath}" \
      "${installHookPatchPath}" \
      "${sdkRoot}" \
      "${cFlags}" \
      "${cxxFlags}" \
      "${sdkDevDir}"
  '';
}
