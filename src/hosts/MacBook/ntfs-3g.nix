# MacBook/ntfs-3g.nix — build polyipseity/ext.ntfs-3g from source.
#
# WHY build from source, not nixpkgs:
#   The polyipseity fork of ntfs-3g (commit f0e5cb0) links against fuse-t, a
#   FSKit-based FUSE implementation distributed as a Homebrew cask at
#   /usr/local/lib/libfuse-t.dylib.  Nix sandbox builds cannot resolve this
#   impure dependency, so we build imperatively during activation.
#
# WHY activation script vs Nix derivation:
#   A pure Nix derivation would require fuse-t headers and dylib inside the
#   sandbox — impractical when fuse-t is a Homebrew cask placed in a fixed
#   system path.  The activation script runs after Homebrew, guaranteeing
#   fuse-t is installed before we build ntfs-3g.
#
# WHY not ntfs-3g from nixpkgs:
#   nixpkgs ntfs-3g uses the native macOS FUSE kext (osxfuse / macFUSE), which
#   requires a kernel extension.  fuse-t is a modern FSKit-based alternative
#   that works without kext approval, so the polyipseity fork is the preferred
#   build on modern macOS.
{ lib, pkgs, ... }:
let
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
  ldFlags = "-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib";
  configureFlags = "--with-fuse=external --prefix=/usr/local --disable-crypto";
  clangBin = "${pkgs.llvmPackages.clang}/bin/clang";
  clangxxBin = "${pkgs.llvmPackages.clang}/bin/clang++";
  buildFingerprint = builtins.hashString "sha256" (
    builtins.concatStringsSep "\n" [
      ntfs3gSrc.outPath
      buildToolsPath
      aclocalPath
      clangBin
      clangxxBin
      cppFlags
      ldFlags
      configureFlags
      cryptoPatchPath
      rootbindirPatchPath
      installHookPatchPath
    ]
  );
in
{
  system.activationScripts.postActivation.text = lib.mkBefore ''
    CURRENT_FINGERPRINT="${buildFingerprint}"
    BUILD_TOOLS_PATH="${buildToolsPath}"
    ACLOCAL_PATH_VALUE="${aclocalPath}"
    NTFS3G_SRC="${ntfs3gSrc}"
    export CC="${clangBin}"
    export CXX="${clangxxBin}"
    export CPPFLAGS="${cppFlags}"
    export LDFLAGS="${ldFlags}"
    CONFIGURE_FLAGS="${configureFlags}"
    CRYPTO_PATCH_PATH="${cryptoPatchPath}"
    ROOTBINDIR_PATCH_PATH="${rootbindirPatchPath}"
    INSTALL_HOOK_PATCH_PATH="${installHookPatchPath}"
    ${builtins.readFile ../../scripts/hosts/MacBook/macos-build-ntfs3g.sh}
  '';
}
