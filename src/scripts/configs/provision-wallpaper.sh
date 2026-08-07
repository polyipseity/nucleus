#!/usr/bin/env bash
# Self-contained wallpaper provisioning script.
# CLI args: is_darwin pictures_dir desktoppr_bin coreutils_bin repo_root current_user sops_symlink_path wallpaper_items_json jq_bin
set -eu

copy_with_reflink() {
  _cwr_src="$1"
  _cwr_dst="$2"
  if cp -L --reflink=auto "$_cwr_src" "$_cwr_dst" 2>/dev/null; then
    return 0
  fi
  cp -L "$_cwr_src" "$_cwr_dst"
}

_is_darwin="$1"
_pictures_dir="$2"
_desktoppr_bin="$3"
_coreutils_bin="$4"
_repo_root="$5"
_current_user="$6"
_sops_symlink_path="$7"

lock_wallpaper_dir() {
  if [ "$_is_darwin" -ne 1 ]; then
    return 0
  fi

  if [ ! -d "$_pictures_dir" ]; then
    return 0
  fi

  if ! chmod 555 "$_pictures_dir"; then
    echo "provision-wallpaper: failed to set read-only mode on wallpaper directory $_pictures_dir." >&2
    return 1
  fi

  if ! /usr/bin/chflags uchg "$_pictures_dir"; then
    echo "provision-wallpaper: failed to set immutable flag on wallpaper directory $_pictures_dir." >&2
    return 1
  fi

  return 0
}

fail_wallpaper_provision() {
  echo "$1" >&2
  if ! lock_wallpaper_dir; then
    echo "provision-wallpaper: failed to re-lock wallpaper directory after an earlier error." >&2
  fi
  exit 1
}

wallpaper_pre_copy_setup() {
  # Refuse to operate on symlinks or non-directories to avoid writing or
  # deleting outside the intended managed wallpaper location.
  if [ -L "$_pictures_dir" ]; then
    fail_wallpaper_provision "provision-wallpaper: wallpaper directory path $_pictures_dir is a symlink; refusing to manage wallpapers there."
  fi

  if [ -e "$_pictures_dir" ] && [ ! -d "$_pictures_dir" ]; then
    fail_wallpaper_provision "provision-wallpaper: wallpaper path $_pictures_dir exists but is not a directory."
  fi

  # Keep the managed wallpaper directory mutable only during activation so
  # users/apps cannot accidentally delete or rename it between runs.
  if [ "$_is_darwin" -eq 1 ] && [ -d "$_pictures_dir" ]; then
    if ! /usr/bin/chflags nouchg "$_pictures_dir"; then
      fail_wallpaper_provision "provision-wallpaper: failed to clear immutable flag on wallpaper directory $_pictures_dir."
    fi

    if ! chmod 755 "$_pictures_dir"; then
      fail_wallpaper_provision "provision-wallpaper: failed to restore writable mode on wallpaper directory $_pictures_dir before managed updates."
    fi
  fi

  mkdir -p "$_pictures_dir"
  chmod 755 "$_pictures_dir"
  if [ "$_is_darwin" -eq 1 ]; then
    if ! /usr/bin/chflags nouchg "$_pictures_dir"; then
      fail_wallpaper_provision "provision-wallpaper: failed to clear immutable flag on wallpaper directory $_pictures_dir after create."
    fi
  fi
}

# Copy each wallpaper from the SOPS decrypted secret directory into
# $_pictures_dir.  Takes a JSON array of wallpaper items, the path to jq,
# and the SOPS symlink path.
wallpaper_provision_copy_items() {
  _items_json="$1"
  _jq_bin="$2"
  _sops_symlink_path="$3"

  _nucleus_wp_failed=0

  while IFS=$'\t' read -r _secretName _wallpaperName; do
    [ -n "$_secretName" ] || continue
    _secretPath="$_sops_symlink_path/$_secretName"
    _targetFile="$_pictures_dir/$_wallpaperName"

    if [ ! -f "$_secretPath" ]; then
      echo "provision-wallpaper: missing decrypted secret at $_secretPath; cannot apply wallpaper gallery." >&2
      _nucleus_wp_failed=1
      break
    fi

    case "$_targetFile" in
      "$_pictures_dir"/*) ;;
      *)
        echo "provision-wallpaper: refusing to write wallpaper outside $_pictures_dir: $_targetFile" >&2
        _nucleus_wp_failed=1
        break
        ;;
    esac

    # Copy decrypted material out of the runtime secret symlink directory
    # so GUI consumers can read a normal file under ~/Pictures.
    if [ -L "$_targetFile" ] || [ ! -f "$_targetFile" ] || ! cmp -s "$_secretPath" "$_targetFile"; then
      _tmpTarget="$(mktemp)"
      copy_with_reflink "$_secretPath" "$_tmpTarget"
      # 444: managed wallpaper content must not be modified outside
      # activation; GUI consumers and desktoppr need only read access.
      chmod 444 "$_tmpTarget"
      mv "$_tmpTarget" "$_targetFile"
    fi
  done < <("$_jq_bin" -r '.[] | [.secretName, .wallpaperName] | @tsv' <<< "$_items_json")

  if [ "$_nucleus_wp_failed" -eq 1 ]; then
    lock_wallpaper_dir
    return 1
  fi
}

wallpaper_provision_symlink_unencrypted() {
  _script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=../lib/resolve-user-config.sh
  . "$_script_dir/../lib/resolve-user-config.sh"
  # shellcheck source=../lib/symlink-hardening.sh
  . "$_script_dir/../lib/symlink-hardening.sh"
  export NUCLEUS_REPO_ROOT="$_repo_root"

  while IFS= read -r _fileName; do
    [ -n "$_fileName" ] || continue
    _sourcePath="$(resolve_wallpaper_unencrypted_file "$_current_user" "$_fileName")"
    _targetFile="$_pictures_dir/$_fileName"
    case "$_targetFile" in
      "$_pictures_dir"/*) ;;
      *)
        fail_wallpaper_provision "provision-wallpaper: refusing to write wallpaper outside $_pictures_dir: $_targetFile"
        ;;
    esac
    ensure_file_symlink "$_sourcePath" "$_targetFile"
  done < <(list_wallpaper_unencrypted_files "$_current_user")
}

wallpaper_post_copy_teardown() {
  # Stale gc: remove decrypted files that no longer have a matching overlay
  # .sops source so the gallery does not show deleted assets.
  _script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=../lib/resolve-user-config.sh
  . "$_script_dir/../lib/resolve-user-config.sh"
  # shellcheck source=../lib/symlink-hardening.sh
  . "$_script_dir/../lib/symlink-hardening.sh"
  export NUCLEUS_REPO_ROOT="$_repo_root"

  for decryptedFile in "$_pictures_dir"/*; do
    [ -e "$decryptedFile" ] || continue
    case "$decryptedFile" in *.xml) continue;; esac
    baseName="$(basename "$decryptedFile")"
    if [ -L "$decryptedFile" ]; then
      if ! resolve_wallpaper_unencrypted_file "$_current_user" "$baseName" >/dev/null 2>&1; then
        _nucleus_unprotect_symlink "provision-wallpaper" "$decryptedFile"
        rm -f "$decryptedFile"
        echo "provision-wallpaper: removed stale wallpaper symlink $baseName (no matching overlay source)."
      fi
      continue
    fi
    [ -f "$decryptedFile" ] || continue
    if resolve_wallpaper_encrypted_blob "$_current_user" "${baseName}.sops" >/dev/null 2>&1; then
      continue
    fi
    rm -f "$decryptedFile"
    echo "provision-wallpaper: removed stale wallpaper $baseName (no matching overlay source)."
  done

  # Apply gallery / slideshow mode.
  # macOS: use desktoppr to set the wallpaper source to the decrypted folder.
  # This avoids brittle AppleScript and private database mutation paths while
  # keeping the assignment in a user-session-safe command line tool.
  # GNOME: generate wallpaper-gallery.xml listing all decrypted images, then
  #        point picture-uri at the XML file.  Each image displays for 595 s
  #        with a 5 s overlay transition (600 s / 10 min total per slide).
  hasWallpapers=0
  for img in "$_pictures_dir"/*; do
    [ -e "$img" ] || continue
    case "$img" in *.xml) continue;; esac
    if [ -f "$img" ] || [ -L "$img" ]; then
      hasWallpapers=1
      break
    fi
  done

  if [ "$hasWallpapers" -ne 1 ]; then
    fail_wallpaper_provision "provision-wallpaper: no decrypted wallpapers found in $_pictures_dir; cannot apply wallpaper gallery."
  fi

  if [ "$_is_darwin" -eq 1 ]; then
    resolvedPicturesDir="$("$_coreutils_bin/readlink" -f "$_pictures_dir" 2>/dev/null || printf '%s' "$_pictures_dir")"
    # desktoppr interprets bare directory paths as their parent; appending
    # '/.' preserves the intended directory so all Spaces follow the gallery.
    desktopprTarget="$resolvedPicturesDir/."

    if [ ! -x "$_desktoppr_bin" ]; then
      fail_wallpaper_provision "provision-wallpaper: desktoppr is not executable at $_desktoppr_bin; cannot set macOS wallpaper gallery."
    elif [ ! -d "$resolvedPicturesDir" ]; then
      fail_wallpaper_provision "provision-wallpaper: resolved wallpaper directory is not a folder: $resolvedPicturesDir"
    else
      if ! "$_desktoppr_bin" all "$desktopprTarget"; then
        fail_wallpaper_provision "provision-wallpaper: desktoppr failed to set wallpaper directory $desktopprTarget."
      fi
    fi
  elif command -v gsettings >/dev/null 2>&1; then
    xmlFile="$_pictures_dir/wallpaper-gallery.xml"
    tmpXml="$(mktemp)"
    firstImg=""
    prevImg=""

    for img in "$_pictures_dir"/*; do
      [ -e "$img" ] || continue
      case "$img" in *.xml) continue;; esac
      if [ ! -f "$img" ] && [ ! -L "$img" ]; then
        continue
      fi

      if [ -z "$firstImg" ]; then
        firstImg="$img"
      fi

      if [ -n "$prevImg" ]; then
        printf '  <transition type="overlay">\n    <duration>5.0</duration>\n    <from>%s</from>\n    <to>%s</to>\n  </transition>\n' \
          "$prevImg" "$img" >> "$tmpXml"
      fi

      printf '  <static>\n    <duration>595.0</duration>\n    <file>%s</file>\n  </static>\n' \
        "$img" >> "$tmpXml"
      prevImg="$img"
    done

    _xml_tmp_final="$(mktemp)"
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<background>\n'
      cat "$tmpXml"
      printf '  <transition type="overlay">\n    <duration>5.0</duration>\n    <from>%s</from>\n    <to>%s</to>\n  </transition>\n' \
        "$prevImg" "$firstImg"
      printf '</background>\n'
    } > "$_xml_tmp_final"
    # 444: the gallery descriptor is regenerated on every activation; GUI
    # consumers need only read access.  Immutability prevents accidental
    # manual edits from silently overriding managed state.
    chmod 444 "$_xml_tmp_final"
    mv "$_xml_tmp_final" "$xmlFile"
    if ! gsettings set org.gnome.desktop.background picture-uri "file://$xmlFile"; then
      fail_wallpaper_provision "provision-wallpaper: failed to set GNOME picture-uri to wallpaper gallery XML."
    fi

    if ! gsettings set org.gnome.desktop.background picture-uri-dark "file://$xmlFile"; then
      fail_wallpaper_provision "provision-wallpaper: failed to set GNOME picture-uri-dark to wallpaper gallery XML."
    fi
    rm -f "$tmpXml"
  fi

  # Lock the directory down after activation to prevent accidental rename,
  # deletion, or entry-level mutation outside managed runs while keeping it
  # readable/traversable for the user and desktop services.
  if ! lock_wallpaper_dir; then
    exit 1
  fi
}

# Entry point
wallpaper_pre_copy_setup
wallpaper_provision_copy_items "$8" "$9" "$_sops_symlink_path"
wallpaper_provision_symlink_unencrypted
wallpaper_post_copy_teardown
