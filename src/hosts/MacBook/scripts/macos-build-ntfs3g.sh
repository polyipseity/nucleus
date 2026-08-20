#!/usr/bin/env bash
# ---- buildNtfs3g ----------------------------------------------------------
# Build polyipseity/ext.ntfs-3g from source.
# Arguments: fingerprint buildToolsPath aclocalPath ntfs3gSrc cc cxx cppFlags
#            linkFlags configureFlags cryptoPatchPath rootbindirPatchPath
#            installHookPatchPath sdkRoot cFlags cxxFlags sdkDevDir
#
# CC/CXX/CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS are exported here so ./configure and
# make resolve them from the environment.
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

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

CURRENT_FINGERPRINT="${1:?ntfs-3g build: missing fingerprint arg}"
BUILD_TOOLS_PATH="${2:?ntfs-3g build: missing buildToolsPath arg}"
ACLOCAL_PATH_VALUE="${3:?ntfs-3g build: missing aclocalPath arg}"
NTFS3G_SRC="${4:?ntfs-3g build: missing ntfs3gSrc arg}"
CC="${5:?ntfs-3g build: missing cc arg}"
CXX="${6:?ntfs-3g build: missing cxx arg}"
CPPFLAGS="${7:?ntfs-3g build: missing cppFlags arg}"
LINK_FLAGS="${8:?ntfs-3g build: missing linkFlags arg}"
CONFIGURE_FLAGS="${9:?ntfs-3g build: missing configureFlags arg}"
CRYPTO_PATCH_PATH="${10:?ntfs-3g build: missing cryptoPatchPath arg}"
ROOTBINDIR_PATCH_PATH="${11:?ntfs-3g build: missing rootbindirPatchPath arg}"
INSTALL_HOOK_PATCH_PATH="${12:?ntfs-3g build: missing installHookPatchPath arg}"
SDK_ROOT="${13:?ntfs-3g build: missing sdkRoot arg}"
C_FLAGS="${14:?ntfs-3g build: missing cFlags arg}"
CXX_FLAGS="${15:?ntfs-3g build: missing cxxFlags arg}"
SDK_DEV_DIR="${16:?ntfs-3g build: missing sdkDevDir arg}"

export CC CXX CPPFLAGS CFLAGS="$C_FLAGS" CXXFLAGS="$CXX_FLAGS"
export SDKROOT="$SDK_ROOT"
# WHY: the nix clang-wrapper's darwin-sdk-setup.bash overrides SDKROOT from
#   DEVELOPER_DIR_arm64_apple_darwin (already set in the activation env via
#   xcode-select --switch) or a hardcoded apple-sdk-14.4 fallback, ignoring the
#   SDKROOT we export.  Pointing DEVELOPER_DIR_arm64_apple_darwin at the
#   enhanced SDK root makes the wrapper resolve the correct SDK instead of
#   erroring with "unable to find sdk: 'macosx'".  Unset DEVELOPER_DIR so the
#   wrapper does not emit "Multiple conflicting values" and fall back to a
#   wrong SDK.
export DEVELOPER_DIR_arm64_apple_darwin="$SDK_DEV_DIR"
unset DEVELOPER_DIR

FINGERPRINT_FILE="/usr/local/share/ntfs-3g/.build-fingerprint"
LOG_FILE="/Users/Shared/nucleus/logs/ntfs-3g-build.log"

if ! [ -x /usr/local/bin/ntfs-3g ] ||
  ! [ -f "$FINGERPRINT_FILE" ] ||
  [ "$(cat "$FINGERPRINT_FILE")" != "$CURRENT_FINGERPRINT" ]; then
  say -l ntfs-3g "building from source... (log: $LOG_FILE)"
  # WHY: prepend (not append) so nix gnumake shadows BSD /usr/bin/make.  BSD
  #   make cannot parse the GNU Makefiles ./configure generates, aborting the
  #   build with "Something went wrong bootstrapping makefile fragments".
  export PATH="$BUILD_TOOLS_PATH:$PATH"
  export ACLOCAL_PATH="$ACLOCAL_PATH_VALUE"
  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cp -r "$NTFS3G_SRC" "$BUILD_DIR/ntfs-3g"
  chmod -R u+w "$BUILD_DIR/ntfs-3g"
  cd "$BUILD_DIR/ntfs-3g" || exit

  /bin/mkdir -p "$(dirname "$LOG_FILE")"
  {
    printf '[%s] ntfs-3g: build started\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    # Patch configure.ac: remove crypto autodetect block (AM_PATH_LIBGCRYPT
    # and PKG_CHECK_MODULES(GNUTLS macros undefined without library deps),
    # fix rootbindir/rootlibdir defaults from /bin:/lib to /usr/local/*
    # (SIP), and fix install-exec-hook to handle missing .so/.dylib files
    # on Darwin.
    printf '[%s] ntfs-3g: patching...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    patch -p1 <"$CRYPTO_PATCH_PATH"
    patch -p1 <"$ROOTBINDIR_PATCH_PATH"
    patch -p1 <"$INSTALL_HOOK_PATCH_PATH"

    printf '[%s] ntfs-3g: running autotools...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    libtoolize --copy --force
    aclocal --force -I m4
    autoheader --force
    automake --add-missing --copy --force-missing
    autoconf --force

    printf '[%s] ntfs-3g: configuring...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    # WHY: keep fuse-t out of LDFLAGS during configure — autoconf link probes
    # fail when every test binary must link fuse-t under nix clang wrappers.
    LDFLAGS=
    ./configure "$CONFIGURE_FLAGS"

    printf '[%s] ntfs-3g: building...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    export LDFLAGS="$LINK_FLAGS"
    make -j"$(sysctl -n hw.ncpu)"
    printf '[%s] ntfs-3g: installing...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    make install
  } >>"$LOG_FILE" 2>&1 || exit_code=$?

  if [ "${exit_code:-0}" -ne 0 ]; then
    error -l ntfs-3g "BUILD FAILED (exit ${exit_code}) — see $(/bin/realpath "$LOG_FILE")"
    exit "$exit_code"
  fi

  printf '[%s] ntfs-3g: build finished\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE" 2>&1

  say -l ntfs-3g "build complete — log at $(/bin/realpath "$LOG_FILE")"

  /bin/mkdir -p "$(dirname "$FINGERPRINT_FILE")"
  echo "$CURRENT_FINGERPRINT" >"$FINGERPRINT_FILE"
fi
