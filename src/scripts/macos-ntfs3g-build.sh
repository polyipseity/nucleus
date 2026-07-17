# ---- buildNtfs3g ----------------------------------------------------------
# Build polyipseity/ext.ntfs-3g from source.
# Expects env vars set by the Nix wrapper in ntfs-3g.nix:
#   CURRENT_FINGERPRINT, BUILD_TOOLS_PATH, ACLOCAL_PATH_VALUE, NTFS3G_SRC,
#   CC, CXX, CPPFLAGS, LDFLAGS, CONFIGURE_FLAGS, CRYPTO_PATCH_PATH,
#   ROOTBINDIR_PATCH_PATH, INSTALL_HOOK_PATCH_PATH
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

FINGERPRINT_FILE="/usr/local/share/ntfs-3g/.build-fingerprint"
LOG_FILE="/Users/Shared/nucleus/logs/ntfs-3g-build.log"

if ! [ -x /usr/local/bin/ntfs-3g ] \
   || ! [ -f "$FINGERPRINT_FILE" ] \
   || [ "$(cat "$FINGERPRINT_FILE")" != "$CURRENT_FINGERPRINT" ]; then
  echo "ntfs-3g: building from source... (log: $LOG_FILE)"
  export PATH="$PATH:$BUILD_TOOLS_PATH"
  export ACLOCAL_PATH="$ACLOCAL_PATH_VALUE"
  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cp -r "$NTFS3G_SRC" "$BUILD_DIR/ntfs-3g"
  chmod -R u+w "$BUILD_DIR/ntfs-3g"
  cd "$BUILD_DIR/ntfs-3g"

  /bin/mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo "=== ntfs-3g build started at $(date) ==="

    # Patch configure.ac: remove crypto autodetect block (AM_PATH_LIBGCRYPT
    # and PKG_CHECK_MODULES(GNUTLS macros undefined without library deps),
    # fix rootbindir/rootlibdir defaults from /bin:/lib to /usr/local/*
    # (SIP), and fix install-exec-hook to handle missing .so/.dylib files
    # on Darwin.
    echo "ntfs-3g: patching..."
    patch -p1 < "$CRYPTO_PATCH_PATH"
    patch -p1 < "$ROOTBINDIR_PATCH_PATH"
    patch -p1 < "$INSTALL_HOOK_PATCH_PATH"

    echo "ntfs-3g: running autotools..."
    libtoolize --copy --force
    aclocal --force -I m4
    autoheader --force
    automake --add-missing --copy --force-missing
    autoconf --force

    echo "ntfs-3g: configuring..."
    ./configure "$CONFIGURE_FLAGS"

    echo "ntfs-3g: building..."
    make -j"$(sysctl -n hw.ncpu)"
    echo "ntfs-3g: installing..."
    make install
  } >> "$LOG_FILE" 2>&1 || exit_code=$?

  if [ "${exit_code:-0}" -ne 0 ]; then
    echo "ntfs-3g: BUILD FAILED (exit ${exit_code}) — see $(/bin/realpath "$LOG_FILE")" >&2
    exit "$exit_code"
  fi

  echo "=== ntfs-3g build finished at $(date) ===" >> "$LOG_FILE" 2>&1

  echo "ntfs-3g: build complete — log at $(/bin/realpath "$LOG_FILE")"

  /bin/mkdir -p "$(dirname "$FINGERPRINT_FILE")"
  echo "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"
fi
