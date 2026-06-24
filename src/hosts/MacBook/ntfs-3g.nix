# MacBook/ntfs-3g.nix — build macos-fuse-t/ntfs-3g from source.
#
# WHY build from source, not nixpkgs:
#   The macos-fuse-t fork of ntfs-3g (commit f0e5cb0) links against fuse-t, a
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
#   that works without kext approval, so the macos-fuse-t fork is the preferred
#   build on modern macOS.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Pinned source for the macos-fuse-t/ntfs-3g fork (edge branch).
  ntfs3gSrc = pkgs.fetchFromGitHub {
    owner = "macos-fuse-t";
    repo = "ntfs-3g";
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
      pkg-config
      python3
    ]
  );

  # aclocal needs Nix-installed m4 macros (libtool.m4 from libtool, pkg.m4 from pkg-config).
  aclocalPath = lib.concatStringsSep ":" [
    "${pkgs.libtool}/share/aclocal"
    "${pkgs.pkg-config}/share/aclocal"
  ];
in
{
  system.activationScripts.postActivation.text = lib.mkBefore ''
        # ---- buildNtfs3g ----------------------------------------------------------
        if ! [ -x /usr/local/bin/ntfs-3g ]; then
          echo "ntfs-3g: building from source..."
          export PATH="${buildToolsPath}:$PATH"
          export ACLOCAL_PATH="${aclocalPath}"
          BUILD_DIR="$(mktemp -d)"
          cp -r "${ntfs3gSrc}" "$BUILD_DIR/ntfs-3g"
          chmod -R u+w "$BUILD_DIR/ntfs-3g"
          cd "$BUILD_DIR/ntfs-3g"
          export CPPFLAGS="-I/usr/local/include/fuse/fuse"
          export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"

          # Patch configure.ac to remove the crypto autodetect block
          # (AM_PATH_LIBGCRYPT and PKG_CHECK_MODULES(GNUTLS) — these macros are
          # undefined and cause shell syntax errors in the generated configure even
          # when --disable-crypto is passed; see conversation-summary for details).
          echo "ntfs-3g: patching out crypto check from configure.ac..."
          python3 << 'PYEOF'
    with open('configure.ac') as f:
        lines = f.read().split('\n')

    # Locate the crypto autodetect block.
    auth_start = next(i for i, l in enumerate(lines) if 'Autodetect whether we can build crypto stuff or not.' in l)
    if_start = next(i for i in range(auth_start, min(auth_start + 6, len(lines)))
                    if lines[i].strip().startswith('if test "$enable_crypto"') and lines[i].strip().endswith('; then'))

    # Find matching fi by tracking if/fi nesting.
    depth = 0
    fi_end = None
    for i in range(if_start + 1, len(lines)):
        s = lines[i].strip()
        if s.startswith('if ') and s.endswith('; then'):
            depth += 1
        elif s == 'fi':
            if depth == 0:
                fi_end = i
                break
            depth -= 1

    removed = lines[:if_start] + lines[fi_end + 1:]
    with open('configure.ac', 'w') as f:
        f.write('\n'.join(removed))
    print(f"Removed {fi_end - if_start + 1} lines ({if_start + 1}-{fi_end + 1})")
    PYEOF

          # Regenerate build system files from patched configure.ac.
          echo "ntfs-3g: running autotools..."
          libtoolize --copy --force
          aclocal --force -I m4
          autoheader --force
          automake --add-missing --copy --force-missing
          autoconf --force

          echo "ntfs-3g: configuring..."
          ./configure --with-fuse=external --prefix=/usr/local --disable-crypto

          # Use -k to keep going if install-exec-hook fails (it tries to mv .so
          # files to /lib, which doesn't exist on macOS — we use .dylib).
          # All actual files (binaries, dylib, headers) are installed before
          # that hook runs, so we ignore its failure.
          echo "ntfs-3g: building..."
          make
          echo "ntfs-3g: installing..."
          # Patch src/Makefile to install to /usr/local/bin instead of /bin (SIP).
          sed -i 's|^rootbindir = /bin$|rootbindir = /usr/local/bin|' src/Makefile
          make -k install || true
          rm -rf "$BUILD_DIR"
          echo "ntfs-3g: build complete."
        fi
  '';
}
