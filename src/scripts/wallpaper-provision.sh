# Helper functions for wallpaper provisioning.
# Intended to be sourced from a Nix activation script.
# Requires: PICTURES_DIR, IS_DARWIN env vars.

lock_wallpaper_dir() {
  if [ "$IS_DARWIN" -ne 1 ]; then
    return 0
  fi

  if [ ! -d "$PICTURES_DIR" ]; then
    return 0
  fi

  if ! chmod 555 "$PICTURES_DIR"; then
    echo "wallpaper-provision: failed to set read-only mode on wallpaper directory $PICTURES_DIR." >&2
    return 1
  fi

  if ! /usr/bin/chflags uchg "$PICTURES_DIR"; then
    echo "wallpaper-provision: failed to set immutable flag on wallpaper directory $PICTURES_DIR." >&2
    return 1
  fi

  return 0
}

fail_wallpaper_provision() {
  echo "$1" >&2
  if ! lock_wallpaper_dir; then
    echo "wallpaper-provision: failed to re-lock wallpaper directory after an earlier error." >&2
  fi
  exit 1
}

wallpaper_pre_copy_setup() {
  # Refuse to operate on symlinks or non-directories to avoid writing or
  # deleting outside the intended managed wallpaper location.
  if [ -L "$PICTURES_DIR" ]; then
    fail_wallpaper_provision "wallpaper-provision: wallpaper directory path $PICTURES_DIR is a symlink; refusing to manage wallpapers there."
  fi

  if [ -e "$PICTURES_DIR" ] && [ ! -d "$PICTURES_DIR" ]; then
    fail_wallpaper_provision "wallpaper-provision: wallpaper path $PICTURES_DIR exists but is not a directory."
  fi

  # Keep the managed wallpaper directory mutable only during activation so
  # users/apps cannot accidentally delete or rename it between runs.
  if [ "$IS_DARWIN" -eq 1 ] && [ -d "$PICTURES_DIR" ]; then
    if ! /usr/bin/chflags nouchg "$PICTURES_DIR"; then
      fail_wallpaper_provision "wallpaper-provision: failed to clear immutable flag on wallpaper directory $PICTURES_DIR."
    fi

    if ! chmod 755 "$PICTURES_DIR"; then
      fail_wallpaper_provision "wallpaper-provision: failed to restore writable mode on wallpaper directory $PICTURES_DIR before managed updates."
    fi
  fi

  mkdir -p "$PICTURES_DIR"
  chmod 755 "$PICTURES_DIR"
  if [ "$IS_DARWIN" -eq 1 ]; then
    if ! /usr/bin/chflags nouchg "$PICTURES_DIR"; then
      fail_wallpaper_provision "wallpaper-provision: failed to clear immutable flag on wallpaper directory $PICTURES_DIR after create."
    fi
  fi
}

# Copy each wallpaper from the SOPS decrypted secret directory into
# $PICTURES_DIR.  Takes a JSON array of wallpaper items, the path to jq,
# and the SOPS symlink path.
wallpaper_provision_copy_items() {
  _items_json="$1"
  _jq_bin="$2"
  _sops_symlink_path="$3"

  _nucleus_wp_failed=0

  while IFS=$'\t' read -r _secretName _wallpaperName; do
    [ -n "$_secretName" ] || continue
    _secretPath="$_sops_symlink_path/$_secretName"
    _targetFile="$PICTURES_DIR/$_wallpaperName"

    if [ ! -f "$_secretPath" ]; then
      echo "wallpaper-provision: missing decrypted secret at $_secretPath; cannot apply wallpaper gallery." >&2
      _nucleus_wp_failed=1
      break
    fi

    case "$_targetFile" in
      "$PICTURES_DIR"/*) ;;
      *)
        echo "wallpaper-provision: refusing to write wallpaper outside $PICTURES_DIR: $_targetFile" >&2
        _nucleus_wp_failed=1
        break
        ;;
    esac

    # Copy decrypted material out of the runtime secret symlink directory
    # so GUI consumers can read a normal file under ~/Pictures.
    if [ -L "$_targetFile" ] || [ ! -f "$_targetFile" ] || ! cmp -s "$_secretPath" "$_targetFile"; then
      _tmpTarget="$(mktemp)"
      cp "$_secretPath" "$_tmpTarget"
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

wallpaper_post_copy_teardown() {
  # Stale gc: remove decrypted files that no longer have a matching
  # .sops source so the gallery does not show deleted assets.
  for decryptedFile in "$PICTURES_DIR"/*; do
    [ -e "$decryptedFile" ] || continue
    [ -f "$decryptedFile" ] || continue
    case "$decryptedFile" in *.xml) continue;; esac
    baseName="$(basename "$decryptedFile")"
    if [ ! -e "${WALLPAPERS_DIR}/${CURRENT_USER}/$baseName.sops" ]; then
      rm -f "$decryptedFile"
      echo "wallpaper-provision: removed stale wallpaper $baseName (no matching .sops source)."
    fi
  done

  # Apply gallery / slideshow mode.
  # macOS: use desktoppr to set the wallpaper source to the decrypted folder.
  # This avoids brittle AppleScript and private database mutation paths while
  # keeping the assignment in a user-session-safe command line tool.
  # GNOME: generate wallpaper-gallery.xml listing all decrypted images, then
  #        point picture-uri at the XML file.  Each image displays for 595 s
  #        with a 5 s overlay transition (600 s / 10 min total per slide).
  hasWallpapers=0
  for img in "$PICTURES_DIR"/*; do
    [ -e "$img" ] || continue
    [ -f "$img" ] || continue
    case "$img" in *.xml) continue;; esac
    hasWallpapers=1
    break
  done

  if [ "$hasWallpapers" -ne 1 ]; then
    fail_wallpaper_provision "wallpaper-provision: no decrypted wallpapers found in $PICTURES_DIR; cannot apply wallpaper gallery."
  fi

  if [ "$IS_DARWIN" -eq 1 ]; then
    resolvedPicturesDir="$("$COREUTILS_BIN/readlink" -f "$PICTURES_DIR" 2>/dev/null || printf '%s' "$PICTURES_DIR")"
    # desktoppr interprets bare directory paths as their parent; appending
    # '/.' preserves the intended directory so all Spaces follow the gallery.
    desktopprTarget="$resolvedPicturesDir/."

    if [ ! -x "$DESKTOPPR_BIN" ]; then
      fail_wallpaper_provision "wallpaper-provision: desktoppr is not executable at $DESKTOPPR_BIN; cannot set macOS wallpaper gallery."
    elif [ ! -d "$resolvedPicturesDir" ]; then
      fail_wallpaper_provision "wallpaper-provision: resolved wallpaper directory is not a folder: $resolvedPicturesDir"
    else
      if ! "$DESKTOPPR_BIN" all "$desktopprTarget"; then
        fail_wallpaper_provision "wallpaper-provision: desktoppr failed to set wallpaper directory $desktopprTarget."
      fi
    fi
  elif command -v gsettings >/dev/null 2>&1; then
    xmlFile="$PICTURES_DIR/wallpaper-gallery.xml"
    tmpXml="$(mktemp)"
    firstImg=""
    prevImg=""

    for img in "$PICTURES_DIR"/*; do
      [ -e "$img" ] || continue
      case "$img" in *.xml) continue;; esac

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
      fail_wallpaper_provision "wallpaper-provision: failed to set GNOME picture-uri to wallpaper gallery XML."
    fi

    if ! gsettings set org.gnome.desktop.background picture-uri-dark "file://$xmlFile"; then
      fail_wallpaper_provision "wallpaper-provision: failed to set GNOME picture-uri-dark to wallpaper gallery XML."
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
