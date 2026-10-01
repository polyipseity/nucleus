#!/usr/bin/env bash
# Builds polyipseity/ext.ntfs-3g from source.
#
# Rebuilds when the installed binary or the build record is missing, when the Nix
# fingerprint (argument 1) changed, or when the observed macFUSE provider digest
# changed. CC/CXX/CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS are exported so ./configure and
# make resolve them from the environment.
#
# WHY build from source in activation rather than from nixpkgs: the polyipseity fork
# (commit f0e5cb0) links against the macFUSE install under /usr/local/lib, an impure
# dependency no sandbox build can resolve, and activation runs after Homebrew so
# macFUSE is installed first. The nixpkgs package instead builds against macFUSE stub
# headers and selects the kernel-extension backend, a kext this host must never
# approve; this fork is built against the installed macFUSE so mounts can select the
# FSKit backend (-o backend=fskit), the kext-free path on macOS 27.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/macos-fuse-provider.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-fuse-provider.sh"

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
FUSE_PROVIDER_PATCH_PATH="${13:?ntfs-3g build: missing fuseProviderPatchPath arg}"
SDK_ROOT="${14:?ntfs-3g build: missing sdkRoot arg}"
C_FLAGS="${15:?ntfs-3g build: missing cFlags arg}"
CXX_FLAGS="${16:?ntfs-3g build: missing cxxFlags arg}"
SDK_DEV_DIR="${17:?ntfs-3g build: missing sdkDevDir arg}"

export CC CXX CPPFLAGS CFLAGS="$C_FLAGS" CXXFLAGS="$CXX_FLAGS"
export SDKROOT="$SDK_ROOT"
# WHY: the nix clang-wrapper's darwin-sdk-setup.bash overrides SDKROOT from
#   DEVELOPER_DIR_arm64_apple_darwin (already set by xcode-select --switch) or a
#   hardcoded apple-sdk-14.4 fallback, ignoring the SDKROOT we export, so pointing
#   it at the enhanced SDK root makes the wrapper resolve the right SDK instead of
#   erroring with "unable to find sdk: 'macosx'". Unset DEVELOPER_DIR so the wrapper
#   does not emit "Multiple conflicting values" and fall back to a wrong SDK.
export DEVELOPER_DIR_arm64_apple_darwin="$SDK_DEV_DIR"
unset DEVELOPER_DIR

FINGERPRINT_FILE="/usr/local/share/ntfs-3g/.build-fingerprint"
LOG_FILE="/Library/Application Support/nucleus/logs/ntfs-3g-build.log"
PROVIDER_ROOT=/usr/local
NTFS3G_BIN=/usr/local/bin/ntfs-3g
PKGUTIL_BIN=/usr/sbin/pkgutil

# Reason the installed ntfs-3g must be rebuilt; prints nothing while current. The observed state is passed in rather than read from the constants above, so the gate can be exercised against fixtures (tests/scripts/macos-build-ntfs3g-tests.sh).
ntfs3g_rebuild_reason() {
  if ! [ -x "$1" ]; then
    printf '%s\n' "binary missing"
  elif ! [ -f "$2" ]; then
    printf '%s\n' "build record missing"
  elif [ "$(fuse_provider_record_field 1 "$2")" != "$3" ]; then
    printf '%s\n' "build configuration changed"
  elif [ "$(fuse_provider_record_field 2 "$2")" != "$4" ]; then
    printf '%s\n' "macFUSE provider changed"
  fi
}

# WHY: macFUSE is an impure build input. Homebrew's cask macfuse@dev declares auto_updates and installs into /usr/local, so the library and headers can be replaced with no repository change and no change to the Nix fingerprint. The digest of the consumed provider files is therefore observed on every activation: without it a macFUSE upgrade leaves the installed ntfs-3g holding an absolute /usr/local/lib/libfuse.<abi>.dylib load path that no longer resolves. The helper is part of buildFingerprint (providerFingerprintScript in ntfs-3g.nix), so an edit that changes what the digest covers without changing its value would leave the field-2 comparison below unchanged.
if ! PROVIDER_DIGEST="$(fuse_provider_digest "$PROVIDER_ROOT")"; then
  error -l ntfs-3g "macFUSE under $PROVIDER_ROOT is not fingerprinted — install or repair it (Homebrew cask macfuse@dev)"
  exit 1
fi

REBUILD_REASON="$(ntfs3g_rebuild_reason "$NTFS3G_BIN" "$FINGERPRINT_FILE" "$CURRENT_FINGERPRINT" "$PROVIDER_DIGEST")"

if [ -n "$REBUILD_REASON" ]; then
  MACFUSE_VERSION="$(macfuse_pkg_version "$PKGUTIL_BIN")" || exit 1
  PROVIDER_IDENTITY="$(fuse_provider_identity "$PROVIDER_ROOT" "$MACFUSE_VERSION")" || exit 1
  say -l ntfs-3g "building from source: $REBUILD_REASON (log: $LOG_FILE)"
  # WHY: prepend (not append) so nix gnumake shadows BSD /usr/bin/make, which cannot parse the GNU Makefiles ./configure generates.
  export PATH="$BUILD_TOOLS_PATH:$PATH"
  export ACLOCAL_PATH="$ACLOCAL_PATH_VALUE"
  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cp -r "$NTFS3G_SRC" "$BUILD_DIR/ntfs-3g"
  chmod -R u+w "$BUILD_DIR/ntfs-3g"
  cd "$BUILD_DIR/ntfs-3g" || exit

  /bin/mkdir -p "$(dirname "$LOG_FILE")"
  {
    printf '[%s] ntfs-3g: build started (provider %s, digest %s)\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$PROVIDER_IDENTITY" "$PROVIDER_DIGEST"

    # WHY: chain every step with && so the group's exit status is the first failure. A rejected patch or a failed autotools/configure step leaves a tree that can still build, so the build would otherwise install sources the fingerprint does not describe and record them as the current install. Chaining rather than exiting, because the group output goes to the log file and an early exit would suppress the console BUILD FAILED report below.
    # WHY: keep macFUSE out of LDFLAGS during configure, since autoconf link probes fail when every test binary must link macFUSE under nix clang wrappers.
    # WHY: pass LDFLAGS on the make command line as well as the export. ./configure writes "LDFLAGS =" (empty) into every Makefile and a Makefile-defined LDFLAGS overrides the environment variable, so without the command-line form the libntfs-3g link loses -framework CoreFoundation and fails on the nfconv calls.
    printf '[%s] ntfs-3g: patching...\n' "$(date '+%Y-%m-%d %H:%M:%S')" &&
      patch -p1 <"$CRYPTO_PATCH_PATH" &&
      patch -p1 <"$ROOTBINDIR_PATCH_PATH" &&
      patch -p1 <"$INSTALL_HOOK_PATCH_PATH" &&
      patch -p1 <"$FUSE_PROVIDER_PATCH_PATH" &&
      printf '[%s] ntfs-3g: running autotools...\n' "$(date '+%Y-%m-%d %H:%M:%S')" &&
      libtoolize --copy --force &&
      aclocal --force -I m4 &&
      autoheader --force &&
      automake --add-missing --copy --force-missing &&
      autoconf --force &&
      printf '[%s] ntfs-3g: configuring...\n' "$(date '+%Y-%m-%d %H:%M:%S')" &&
      LDFLAGS="" ./configure "$CONFIGURE_FLAGS" &&
      printf '[%s] ntfs-3g: building...\n' "$(date '+%Y-%m-%d %H:%M:%S')" &&
      export LDFLAGS="$LINK_FLAGS" &&
      make -j"$(sysctl -n hw.ncpu)" LDFLAGS="$LINK_FLAGS" &&
      {
        printf '[%s] ntfs-3g: installing...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        make install LDFLAGS="$LINK_FLAGS"
      }
  } >>"$LOG_FILE" 2>&1 || exit_code=$?

  if [ "${exit_code:-0}" -ne 0 ]; then
    error -l ntfs-3g "BUILD FAILED (exit ${exit_code}) — see $(/bin/realpath "$LOG_FILE")"
    exit "$exit_code"
  fi

  printf '[%s] ntfs-3g: build finished\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE" 2>&1

  say -l ntfs-3g "build complete — log at $(/bin/realpath "$LOG_FILE")"

  /bin/mkdir -p "$(dirname "$FINGERPRINT_FILE")"
  # Line 1 is the Nix fingerprint and line 2 the provider digest; both gate the next rebuild. Line 3 names the provider for diagnostics and never gates anything.
  printf '%s\n%s\n%s\n' "$CURRENT_FINGERPRINT" "$PROVIDER_DIGEST" "$PROVIDER_IDENTITY" >"$FINGERPRINT_FILE"
fi
