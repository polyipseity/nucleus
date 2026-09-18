# shellcheck shell=sh
#
# macFUSE provider fingerprinting for the source-built ntfs-3g (macOS).
#
# The ntfs-3g build consumes the macFUSE installation under the provider root:
# include/fuse/*.h, lib/libfuse.dylib and lib/pkgconfig/fuse.pc.  macFUSE is
# installed by Homebrew, and its cask declares auto_updates, so those files can
# be replaced with no repository change and no Nix evaluation change.  The files
# themselves are therefore the authority for "has the provider changed since
# this binary was built?".
#
# WHY: hash the consumed files instead of recording a version:
#   The pinned cask carries no version into the build fingerprint, and a package
#   receipt can disagree with what is actually on disk.  Hashing the consumed
#   files catches both a version upgrade and an in-place replacement.
#
# Provides:
#   fuse_provider_lib_name <provider_root>    — resolved libfuse basename
#   fuse_provider_digest <provider_root>      — sha256 over the consumed files
#   fuse_provider_identity <root> <version>   — informational build-record line
#   fuse_provider_record_field <line> <file>  — one line of the build record
#   macfuse_pkg_version                       — installed macFUSE package version
#
# Requires sha256_of_file() and error() from src/scripts/lib/lib.sh.
#
# The provider root is a parameter rather than a constant so callers and tests
# can point at any macFUSE installation shape.

# WHY: every message from this helper names the ntfs-3g activation build, its
#   only consumer.  lib.sh derives the default label from $0, which would report
#   one failure under two labels — the helper's and the step's.
_fp_error() {
  error -l ntfs-3g "$@"
}

# Resolved path of the provider library, following the macFUSE symlink
# (libfuse.dylib -> libfuse.2.dylib).  Returns 1 when it is absent or dangling.
_fp_resolved_lib() {
  [ -e "$1/lib/libfuse.dylib" ] || return 1
  /bin/realpath "$1/lib/libfuse.dylib"
}

# Append one "relative_path hash" entry to a manifest, failing when the file
# cannot be hashed.
#
# WHY: sha256_of_file prints nothing and still succeeds for a file it cannot
#   read, so an unchecked call would record an empty hash — a digest over a
#   provider whose contents were never read.
_fp_manifest_entry() { # <manifest_file> <relative_path>
  _fpme_hash="$(sha256_of_file "$2")" || return 1
  [ -n "$_fpme_hash" ] || return 1
  printf '%s %s\n' "$2" "$_fpme_hash" >>"$1"
}

# Basename of the resolved provider library, e.g. libfuse.2.dylib.
fuse_provider_lib_name() {
  _fpln_lib="$(_fp_resolved_lib "$1")" || return 1
  printf '%s\n' "${_fpln_lib##*/}"
}

# sha256 over the consumed provider files: every regular file under
# include/fuse/, the resolved library, and lib/pkgconfig/fuse.pc.  The digest is
# content-addressed over a sorted "path hash" manifest, so it is independent of
# directory order, of where the provider root lives, and of the temporary file
# name used to build the manifest.  The root is canonicalized first, so it is
# also independent of how the caller spells it (symlinked components included).
# A provider file that cannot be read fails the digest instead of contributing an
# empty hash.
#
# WHY: record the library under its resolved relative path:
#   a macFUSE ABI bump (libfuse.2 -> libfuse.3) changes the digest even when the
#   bytes are identical, which is the case that a content-only hash misses.
fuse_provider_digest() {
  _fpd_root="$1"
  if ! [ -f "$_fpd_root/include/fuse/fuse.h" ]; then
    _fp_error "macFUSE headers not found under $_fpd_root/include/fuse"
    return 1
  fi
  if ! [ -f "$_fpd_root/lib/pkgconfig/fuse.pc" ]; then
    _fp_error "macFUSE pkg-config file not found at $_fpd_root/lib/pkgconfig/fuse.pc"
    return 1
  fi
  # WHY: canonicalize the root before deriving relative manifest names.  The
  #   library path below comes from realpath, so a root reached through a
  #   symlinked component (/var -> /private/var, which is how $TMPDIR is spelled
  #   on macOS) would otherwise survive the prefix strip and leak an absolute
  #   path into the manifest — making the digest depend on how the caller spelled
  #   the root, and so rebuild on a spelling change alone.
  _fpd_root="$(/bin/realpath "$_fpd_root")" || {
    _fp_error "macFUSE provider root is not resolvable: $1"
    return 1
  }
  _fpd_lib="$(_fp_resolved_lib "$_fpd_root")" || {
    _fp_error "macFUSE library not found at $_fpd_root/lib/libfuse.dylib"
    return 1
  }

  _fpd_manifest="$(mktemp)" || {
    _fp_error "could not create a temporary file for the macFUSE provider manifest"
    return 1
  }
  # WHY: run find from inside the provider root so every manifest entry is a
  #   path relative to it — the digest then depends only on relative names and
  #   contents, never on the provider root's own location.  mktemp returns an
  #   absolute path, so the entry helper works from inside that root too.
  # WHY: every step fails the whole digest instead of recording a partial
  #   provider.  A truncated entry list (find or sort failing, or an unreadable
  #   file) would otherwise be recorded as a valid fingerprint, which is exactly
  #   the drift the build record exists to detect.
  _fpd_lib_rel="${_fpd_lib#"$_fpd_root"/}"
  if ! (
    cd "$_fpd_root" || exit 1
    _fpd_files="$(find include/fuse -type f -print)" || exit 1
    [ -n "$_fpd_files" ] || exit 1
    printf '%s\n' "$_fpd_files" | LC_ALL=C sort | while IFS= read -r _fpd_file; do
      _fp_manifest_entry "$_fpd_manifest" "$_fpd_file" || exit 1
    done || exit 1
    _fp_manifest_entry "$_fpd_manifest" "lib/pkgconfig/fuse.pc" || exit 1
    _fp_manifest_entry "$_fpd_manifest" "$_fpd_lib_rel" || exit 1
  ); then
    rm -f "$_fpd_manifest"
    _fp_error "could not fingerprint the macFUSE provider under $_fpd_root"
    return 1
  fi
  if ! LC_ALL=C sort -o "$_fpd_manifest" "$_fpd_manifest"; then
    rm -f "$_fpd_manifest"
    _fp_error "could not sort the macFUSE provider manifest"
    return 1
  fi
  if ! _fpd_digest="$(sha256_of_file "$_fpd_manifest")" || [ -z "$_fpd_digest" ]; then
    rm -f "$_fpd_manifest"
    _fp_error "could not hash the macFUSE provider manifest"
    return 1
  fi
  rm -f "$_fpd_manifest"
  printf '%s\n' "$_fpd_digest"
}

# Informational build-record line naming the provider the binary was built
# against.  Never gates a rebuild: a version string must not churn rebuilds.
fuse_provider_identity() { # <provider_root> <macfuse_version>
  _fpi_lib="$(fuse_provider_lib_name "$1")" || return 1
  printf 'macfuse %s %s\n' "$2" "$_fpi_lib"
}

# One line of the ntfs-3g build record (1 = Nix fingerprint, 2 = provider
# digest, 3 = provider identity).  Prints nothing and returns 1 when the record
# does not exist; a record written by an older revision has fewer lines, which
# the caller observes as an empty field.
fuse_provider_record_field() { # <line_number> <record_file>
  [ -f "$2" ] || return 1
  sed -n "${1}p" "$2"
}

# Installed macFUSE package version from the installer receipt, e.g. 5.3.3.
# Fails loudly when the receipt is absent: an unidentifiable provider is exactly
# the state the build record exists to expose, so it must not be papered over.
macfuse_pkg_version() {
  _mpv_version="$(/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core | awk '/^version:/ { print $2 }')"
  if [ -z "$_mpv_version" ]; then
    _fp_error "macFUSE package receipt not found (io.macfuse.installer.components.core)"
    return 1
  fi
  printf '%s\n' "$_mpv_version"
}
