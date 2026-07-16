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
    # ---- buildNtfs3g ----------------------------------------------------------
    FINGERPRINT_FILE="/usr/local/share/ntfs-3g/.build-fingerprint"
    CURRENT_FINGERPRINT="${buildFingerprint}"
    LOG_FILE="/Users/Shared/nucleus/logs/ntfs-3g-build.log"

    if ! [ -x /usr/local/bin/ntfs-3g ] \
       || ! [ -f "$FINGERPRINT_FILE" ] \
       || [ "$(cat "$FINGERPRINT_FILE")" != "$CURRENT_FINGERPRINT" ]; then
      echo "ntfs-3g: building from source... (log: $LOG_FILE)"
      export PATH="$PATH:${buildToolsPath}"
      export ACLOCAL_PATH="${aclocalPath}"
      BUILD_DIR="$(mktemp -d)"
      trap 'rm -rf "$BUILD_DIR"' EXIT
      cp -r "${ntfs3gSrc}" "$BUILD_DIR/ntfs-3g"
      chmod -R u+w "$BUILD_DIR/ntfs-3g"
      cd "$BUILD_DIR/ntfs-3g"
      export CC="${clangBin}"
      export CXX="${clangxxBin}"
      export CPPFLAGS="${cppFlags}"
      export LDFLAGS="${ldFlags}"

      /bin/mkdir -p "$(dirname "$LOG_FILE")"
      {
        echo "=== ntfs-3g build started at $(date) ==="

        # Patch configure.ac: remove crypto autodetect block (AM_PATH_LIBGCRYPT
        # and PKG_CHECK_MODULES(GNUTLS macros undefined without library deps),
        # fix rootbindir/rootlibdir defaults from /bin:/lib to /usr/local/*
        # (SIP), and fix install-exec-hook to handle missing .so/.dylib files
        # on Darwin.
        echo "ntfs-3g: patching..."
        patch -p1 < ${cryptoPatchPath}
        patch -p1 < ${rootbindirPatchPath}
        patch -p1 < ${installHookPatchPath}

        echo "ntfs-3g: running autotools..."
        libtoolize --copy --force
        aclocal --force -I m4
        autoheader --force
        automake --add-missing --copy --force-missing
        autoconf --force

        echo "ntfs-3g: configuring..."
        ./configure ${configureFlags}

        echo "ntfs-3g: building..."
        make -j"$(sysctl -n hw.ncpu)"
        echo "ntfs-3g: installing..."
        make install
      } >> "$LOG_FILE" 2>&1 || exit_code=$?

      if [ "''${exit_code:-0}" -ne 0 ]; then
        echo "ntfs-3g: BUILD FAILED (exit ''${exit_code}) — see $(/bin/realpath "$LOG_FILE")" >&2
        exit "$exit_code"
      fi

      echo "=== ntfs-3g build finished at $(date) ===" >> "$LOG_FILE" 2>&1

      echo "ntfs-3g: build complete — log at $(/bin/realpath "$LOG_FILE")"

      /bin/mkdir -p "$(dirname "$FINGERPRINT_FILE")"
      echo "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"
    fi
  '';
}
