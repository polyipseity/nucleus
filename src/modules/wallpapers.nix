# modules/wallpapers.nix — Home Manager activation hook that decrypts SOPS-
# encrypted wallpaper blobs and configures a slideshow / gallery desktop.
#
# Asset layout: assets/wallpapers/<username>/*.sops — each subdirectory
# represents a user, and all .sops files inside belong to that user.  Files
# are encrypted with SOPS (age via machine SSH key or GPG fallback).  On
# activation the blobs are decrypted into ~/Pictures/wallpapers/ and applied
# as a rotating gallery (10-minute interval) on both macOS (desktoppr folder
# mode) and GNOME (dynamically generated wallpaper-gallery.xml).
#
# Multi-user support: each subdirectory in assets/wallpapers/ is treated as a
# separate user.  Home Manager activation for each user runs the provision
# script to their own ~/Pictures/wallpapers/ directory.
#
# Stale cleanup: any file in ~/Pictures/wallpapers/ that no longer has a
# matching *.sops source is removed so the gallery stays current.
#
# This activation runs after gpgImport so the keyring import has already
# happened before wallpaper decryption attempts.
{ config, lib, pkgs, ... }:
let
  wallpapersDir = ../assets/wallpapers;

  # Get all user subdirectories (each is a username).
  userDirs = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory")
    (builtins.readDir wallpapersDir)
  );

  # Convert a wallpaper filename into a stable secret key suffix so sops-nix
  # keys remain path-safe while still being traceable to the source file.
  sanitizeSecretSuffix = value:
    lib.replaceStrings
      [ " " "(" ")" "." "-" ]
      [ "_" "" "" "_" "_" ]
      value;

  # For each user, collect their wallpaper blobs from their subdirectory.
  wallpaperBlobsForUser = userName:
    lib.attrNames (
      lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".sops" name)
        (builtins.readDir (wallpapersDir + "/${userName}"))
    );

  currentUsername = config.home.username;
  currentUserHome = config.home.homeDirectory;

  # Generate wallpaper secrets for a given user.
  mkWallpaperSecretsForUser = userName:
    let
      blobs = wallpaperBlobsForUser userName;
      items = map
        (blobName:
          let
            wallpaperName = lib.removeSuffix ".sops" blobName;
          in {
            inherit blobName wallpaperName;
            secretName = "wallpaper_${sanitizeSecretSuffix wallpaperName}_${userName}";
          })
        blobs;
    in
    lib.listToAttrs (map
      (item: {
        name = item.secretName;
        value = {
          format = "binary";
          mode = "0400";
          sopsFile = builtins.path {
            path = wallpapersDir + "/${userName}/${item.blobName}";
            name = "wallpaper-${sanitizeSecretSuffix item.blobName}";
          };
        };
      })
      items);

  # Generate wallpaper secrets for ALL user directories.
  wallpaperSecrets =
    lib.foldl' lib.recursiveUpdate {} (map mkWallpaperSecretsForUser userDirs);

  # Items list for the activation script - use current user's secrets.
  wallpaperBlobsCurrentUser = wallpaperBlobsForUser currentUsername;
  wallpaperItemsForCurrentUser = map
    (blobName:
      let
        wallpaperName = lib.removeSuffix ".sops" blobName;
      in {
        inherit blobName wallpaperName;
        secretName = "wallpaper_${sanitizeSecretSuffix wallpaperName}_${currentUsername}";
      })
    wallpaperBlobsCurrentUser;
in
{
  assertions = [
    {
      assertion = builtins.pathExists wallpapersDir;
      message = "wallpapers: required wallpapers directory is missing.";
    }
    {
      assertion = builtins.any (u: u == currentUsername) userDirs;
      message = "wallpapers: current user has no managed wallpaper directory.";
    }
  ];

  sops.secrets = wallpaperSecrets;

  home.activation.wallpaperProvision = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    export HOME="${currentUserHome}"

    picturesDir="$HOME/Pictures/wallpapers"
    isDarwin=0
    if [ "$(uname -s)" = "Darwin" ]; then
      isDarwin=1
    fi

    # Keep locking behavior in one function so failures can reapply directory
    # protections before exiting and avoid leaving a mutable target behind.
    lock_wallpaper_dir() {
      if [ "$isDarwin" -ne 1 ]; then
        return 0
      fi

      if [ ! -d "$picturesDir" ]; then
        return 0
      fi

      if ! chmod 555 "$picturesDir"; then
        echo "wallpaperProvision: failed to set read-only mode on wallpaper directory $picturesDir." >&2
        return 1
      fi

      if ! /usr/bin/chflags uchg "$picturesDir"; then
        echo "wallpaperProvision: failed to set immutable flag on wallpaper directory $picturesDir." >&2
        return 1
      fi

      return 0
    }

    fail_wallpaper_provision() {
      echo "$1" >&2
      if ! lock_wallpaper_dir; then
        echo "wallpaperProvision: failed to re-lock wallpaper directory after an earlier error." >&2
      fi
      exit 1
    }

    # Refuse to operate on symlinks or non-directories to avoid writing or
    # deleting outside the intended managed wallpaper location.
    if [ -L "$picturesDir" ]; then
      fail_wallpaper_provision "wallpaperProvision: wallpaper directory path $picturesDir is a symlink; refusing to manage wallpapers there."
    fi

    if [ -e "$picturesDir" ] && [ ! -d "$picturesDir" ]; then
      fail_wallpaper_provision "wallpaperProvision: wallpaper path $picturesDir exists but is not a directory."
    fi

    # Keep the managed wallpaper directory mutable only during activation so
    # users/apps cannot accidentally delete or rename it between runs.
    if [ "$isDarwin" -eq 1 ] && [ -d "$picturesDir" ]; then
      if ! /usr/bin/chflags nouchg "$picturesDir"; then
        fail_wallpaper_provision "wallpaperProvision: failed to clear immutable flag on wallpaper directory $picturesDir."
      fi

      if ! chmod 755 "$picturesDir"; then
        fail_wallpaper_provision "wallpaperProvision: failed to restore writable mode on wallpaper directory $picturesDir before managed updates."
      fi
    fi

    mkdir -p "$picturesDir"
    chmod 755 "$picturesDir"
    if [ "$isDarwin" -eq 1 ]; then
      if ! /usr/bin/chflags nouchg "$picturesDir"; then
        fail_wallpaper_provision "wallpaperProvision: failed to clear immutable flag on wallpaper directory $picturesDir after create."
      fi
    fi

    ${lib.concatMapStringsSep "\n"
      (item: ''
        secretPath="${config.sops.defaultSymlinkPath}/${item.secretName}"
        targetFile="$picturesDir/${item.wallpaperName}"

        if [ ! -f "$secretPath" ]; then
          fail_wallpaper_provision "wallpaperProvision: missing decrypted wallpaper secret at $secretPath; cannot apply wallpaper gallery."
        fi

        case "$targetFile" in
          "$picturesDir"/*) ;;
          *)
            fail_wallpaper_provision "wallpaperProvision: refusing to write wallpaper outside $picturesDir: $targetFile"
            ;;
        esac

        # Copy decrypted material out of the runtime secret symlink directory
        # so GUI consumers can read a normal file under ~/Pictures.
        if [ -L "$targetFile" ] || [ ! -f "$targetFile" ] || ! cmp -s "$secretPath" "$targetFile"; then
          tmpTarget="$(mktemp)"
          cp "$secretPath" "$tmpTarget"
          # 444: managed wallpaper content must not be modified outside
          # activation; GUI consumers and desktoppr need only read access.
          chmod 444 "$tmpTarget"
          mv "$tmpTarget" "$targetFile"
        fi
      '')
      wallpaperItemsForCurrentUser}

    # Stale cleanup: remove decrypted files that no longer have a matching
    # .sops source so the gallery does not show deleted assets.
    for decryptedFile in "$picturesDir"/*; do
      [ -e "$decryptedFile" ] || continue
      [ -f "$decryptedFile" ] || continue
      case "$decryptedFile" in *.xml) continue;; esac
      baseName="$(basename "$decryptedFile")"
      if [ ! -e "${wallpapersDir}/${currentUsername}/$baseName.sops" ]; then
        rm -f "$decryptedFile"
        echo "wallpaperProvision: removed stale wallpaper $baseName (no matching .sops source)."
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
    for img in "$picturesDir"/*; do
      [ -e "$img" ] || continue
      [ -f "$img" ] || continue
      case "$img" in *.xml) continue;; esac
      hasWallpapers=1
      break
    done

    if [ "$hasWallpapers" -ne 1 ]; then
      fail_wallpaper_provision "wallpaperProvision: no decrypted wallpapers found in $picturesDir; cannot apply wallpaper gallery."
    fi

    if [ "$isDarwin" -eq 1 ]; then
      desktopprBin="${pkgs.desktoppr}/bin/desktoppr"
      resolvedPicturesDir="$(${pkgs.coreutils}/bin/readlink -f "$picturesDir" 2>/dev/null || printf '%s' "$picturesDir")"
      # desktoppr interprets bare directory paths as their parent; appending
      # '/.' preserves the intended directory so all Spaces follow the gallery.
      desktopprTarget="$resolvedPicturesDir/."

      if [ ! -x "$desktopprBin" ]; then
        fail_wallpaper_provision "wallpaperProvision: desktoppr is not executable at $desktopprBin; cannot set macOS wallpaper gallery."
      elif [ ! -d "$resolvedPicturesDir" ]; then
        fail_wallpaper_provision "wallpaperProvision: resolved wallpaper directory is not a folder: $resolvedPicturesDir"
      else
        if ! "$desktopprBin" all "$desktopprTarget"; then
          fail_wallpaper_provision "wallpaperProvision: desktoppr failed to set wallpaper directory $desktopprTarget."
        fi
      fi
    elif command -v gsettings >/dev/null 2>&1; then
      xmlFile="$picturesDir/wallpaper-gallery.xml"
      tmpXml="$(mktemp)"
      firstImg=""
      prevImg=""

      for img in "$picturesDir"/*; do
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
        fail_wallpaper_provision "wallpaperProvision: failed to set GNOME picture-uri to wallpaper gallery XML."
      fi

      if ! gsettings set org.gnome.desktop.background picture-uri-dark "file://$xmlFile"; then
        fail_wallpaper_provision "wallpaperProvision: failed to set GNOME picture-uri-dark to wallpaper gallery XML."
      fi
      rm -f "$tmpXml"
    fi

    # Lock the directory down after activation to prevent accidental rename,
    # deletion, or entry-level mutation outside managed runs while keeping it
    # readable/traversable for the user and desktop services.
    if ! lock_wallpaper_dir; then
      exit 1
    fi
  '';
}
