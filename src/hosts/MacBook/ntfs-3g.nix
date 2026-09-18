# MacBook/ntfs-3g.nix — build polyipseity/ext.ntfs-3g from source.
#
# WHY: build from source, not nixpkgs:
#   The polyipseity fork of ntfs-3g (commit f0e5cb0) links against the macFUSE
#   installation at /usr/local/lib/libfuse.dylib, an impure dependency that Nix
#   sandbox builds cannot resolve, so we build imperatively during activation.
#
# WHY: activation script vs Nix derivation:
#   A pure Nix derivation would require macFUSE headers and dylib inside the
#   sandbox — impractical when macFUSE is installed into fixed system paths.
#   The activation script runs after Homebrew, guaranteeing macFUSE is installed
#   before we build ntfs-3g.
#
# WHY: not ntfs-3g from nixpkgs:
#   The nixpkgs package builds against macFUSE stub headers rather than the
#   installed macFUSE, so its build does not track the provider this host runs.
#   This fork is built against the installed macFUSE and mounts with
#   -o backend=fskit, the kext-free path on macOS 27; the macFUSE kernel
#   extension is never approved here.
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
  fuseProviderPatchPath = ./patches/ntfs-3g-fuse-provider.patch;

  # Build parameters (extracted for fingerprint-based rebuild detection).
  # macFUSE's fuse.pc declares Cflags: -I/usr/local/include/fuse
  # -D_FILE_OFFSET_BITS=64.  The pinned fork's configure.ac has no fuse
  # pkg-config check, so the compile flags are passed explicitly instead.
  cppFlags = "-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64";
  # WHY: macFUSE is linked by absolute dylib path from the patched
  #   src/Makefile.am (fuseProviderPatchPath), never as -lfuse.  macFUSE also
  #   installs /usr/local/lib/libfuse.la, whose dependency_libs names
  #   -liconv -licucore; libtool would inherit those into libntfs-3g.la and from
  #   there onto every ntfsprogs link, and the nixpkgs apple-sdk ships no
  #   libiconv/libicucore stubs, so those links fail with "library not found".
  # WHY: ENABLE_NFCONV is enabled by default on darwin (configure.ac), so
  #   libntfs-3g/unistr.c calls CoreFoundation APIs
  #   (_CFStringNormalize, _CFRelease, ...) but upstream's Makefile.am never
  #   links the framework.  Add it here so the libntfs-3g.la link resolves.
  #   linkFlags flows only into make LDFLAGS (configure uses empty LDFLAGS=),
  #   so this does not affect autoconf probes.
  linkFlags = "-framework CoreFoundation";
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
  # WHY: the build script drives the whole procedure (patch order, autotools,
  #   configure/make invocation, install chaining), so its content belongs in
  #   the fingerprint.  A path interpolated into the fingerprint is copied to
  #   the store, making the recorded hash content-addressed; without it a
  #   script-only edit would leave the previous /usr/local install in place.
  buildScriptPath = ./scripts/macos-build-ntfs3g.sh;
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
      fuseProviderPatchPath
      buildScriptPath
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
      "${fuseProviderPatchPath}" \
      "${sdkRoot}" \
      "${cFlags}" \
      "${cxxFlags}" \
      "${sdkDevDir}"
  '';
}
