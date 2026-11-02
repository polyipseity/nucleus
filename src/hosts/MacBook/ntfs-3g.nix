# MacBook/ntfs-3g.nix - build polyipseity/ext.ntfs-3g from source against fuse-t.
#
# WHY from source in activation and not from nixpkgs: the fork links
# /usr/local/lib/libfuse-t.dylib, an impure dependency a sandbox build cannot
# resolve, so the build runs in activation after Homebrew has installed fuse-t.
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

  # fuse-t's fuse-t.pc declares "Cflags: -I/usr/local/include/fuse" (a symlink into
  # the fuse-t application support tree), but the fork's configure.ac has no fuse
  # cflags check, so the include directory and the offset-bits define are passed
  # explicitly here.
  cppFlags = "-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64";
  # WHY the rpath: /usr/local/lib/libfuse-t.dylib carries the install name
  # @rpath/libfuse-t.dylib (otool -D), so linking it, by absolute path or not,
  # records @rpath/libfuse-t.dylib in the binary and dyld aborts with "no LC_RPATH's
  # found" unless the binary also carries /usr/local/lib as an rpath.
  # WHY CoreFoundation: ENABLE_NFCONV defaults on darwin, so unistr.c calls
  # CoreFoundation APIs that upstream's Makefile.am never links. linkFlags flows
  # only into make LDFLAGS, so autoconf probes are unaffected.
  linkFlags = "-framework CoreFoundation -Wl,-rpath,/usr/local/lib";
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
  # WHY fingerprint the provider helper: the build's provider digest and identity
  # come from it, so an edit that changes what the digest covers would otherwise
  # leave field 2 of the build record unchanged.
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
