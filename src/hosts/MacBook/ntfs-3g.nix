# MacBook/ntfs-3g.nix - build polyipseity/ext.ntfs-3g from source.
#
# WHY from source and not nixpkgs: the nixpkgs package builds against macFUSE
# stub headers rather than the installed macFUSE, so it does not track the
# provider this host runs. This fork builds against the installed macFUSE and
# mounts with -o backend=fskit, the kext-free path on macOS 27; the macFUSE
# kernel extension is never approved here.
#
# WHY an activation script and not a derivation: the fork links against
# /usr/local/lib/libfuse.dylib, an impure dependency a Nix sandbox build cannot
# resolve. Activation runs after Homebrew, so macFUSE exists by then.
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
  appleSdkEnhanced = import ../../modules/lib/apple-sdk-enhanced.nix { inherit pkgs lib; };
  sdkRoot = "${appleSdkEnhanced}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
  # WHY: the nix clang-wrapper's darwin-sdk-setup.bash overrides SDKROOT from
  # DEVELOPER_DIR_arm64_apple_darwin (set by xcode-select --switch) or a
  # hardcoded apple-sdk-14.4 fallback, so pointing that variable at the enhanced
  # SDK root is what makes the wrapper resolve the right SDK instead of failing
  # with "unable to find sdk: 'macosx'".
  sdkDevDir = appleSdkEnhanced;
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

  # aclocal needs the m4 macros Nix installs (libtool.m4, pkg.m4).
  aclocalPath = lib.concatStringsSep ":" [
    "${pkgs.libtool}/share/aclocal"
    "${pkgs.pkg-config}/share/aclocal"
  ];

  cryptoPatchPath = ./patches/ntfs-3g-crypto.patch;
  rootbindirPatchPath = ./patches/ntfs-3g-rootbindir.patch;
  installHookPatchPath = ./patches/ntfs-3g-install-hook.patch;
  fuseProviderPatchPath = ./patches/ntfs-3g-fuse-provider.patch;

  # macFUSE's fuse.pc declares these Cflags, but the fork's configure.ac has no
  # fuse pkg-config check, so they are passed explicitly instead.
  cppFlags = "-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64";
  # WHY absolute dylib and not -lfuse: the patched src/Makefile.am links macFUSE
  # by path. macFUSE's /usr/local/lib/libfuse.la names -liconv -licucore as
  # dependency_libs, which libtool would push onto every ntfsprogs link, and the
  # nixpkgs apple-sdk ships no stubs for those, so the links fail.
  # WHY CoreFoundation: ENABLE_NFCONV defaults on darwin, so unistr.c calls
  # CoreFoundation APIs that upstream's Makefile.am never links. linkFlags flows
  # only into make LDFLAGS, so autoconf probes are unaffected.
  linkFlags = "-framework CoreFoundation";
  configureFlags = "--with-fuse=external --prefix=/usr/local --disable-crypto --disable-plugins";
  clangBin = "${pkgs.llvmPackages.clang}/bin/clang";
  clangxxBin = "${pkgs.llvmPackages.clang}/bin/clang++";
  # WHY gnu17 and not the autoconf-detected gnu23: clang 21 makes an undeclared
  # call a hard error under gnu23, so every AC_CHECK_FUNC probe fails and
  # configure aborts with "Unable to find libdl". gnu17 makes it a warning.
  cFlags = "-std=gnu17";
  cxxFlags = "-std=gnu17";
  # WHY fingerprint the build script: a path in the fingerprint is copied to the
  # store, so a script-only edit would otherwise leave the previous /usr/local
  # install in place.
  buildScriptPath = ./scripts/macos-build-ntfs3g.sh;
  # WHY fingerprint the provider helper: an edit that is a no-op over the current
  # tree (say, a find narrowed to the top level) leaves the digest unchanged, so
  # the recorded provider field could not notice it.
  providerFingerprintScript = ../../scripts/lib/macos-fuse-provider.sh;
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
      providerFingerprintScript
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
