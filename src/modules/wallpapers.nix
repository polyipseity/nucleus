# modules/wallpapers.nix — Home Manager activation hook that decrypts SOPS-
# encrypted wallpaper blobs and configures a slideshow / gallery desktop.
#
# Asset layout: assets/wallpapers/*.sops — each file is a binary image
# encrypted with SOPS (age via host SSH key or GPG fallback).  On activation
# the blobs are decrypted into ~/Pictures/wallpapers/ and applied as a
# rotating gallery (10-minute interval) on both macOS (osascript folder mode)
# and GNOME (dynamically generated nucleus-gallery.xml).
#
# Stale cleanup: any file in ~/Pictures/wallpapers/ that no longer has a
# matching *.sops source is removed so the gallery stays current.
#
# This activation runs after nucleusKeyProvision so that the GPG keyring and
# SSH keys are already in place before decryption is attempted.
{ config, lib, pkgs, ... }:
let
  # Path to the ed25519 host key used as the SOPS age recipient.
  hostSshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  # Nix store path to the wallpaper blob directory (evaluated at build time).
  wallpapersDir = ../../assets/wallpapers;
in
{
  # Fail fast at eval time if the expected asset directory is absent from the repo.
  assertions = [
    {
      assertion = builtins.pathExists wallpapersDir;
      message = "nucleus: required wallpapers directory is missing at ${toString wallpapersDir}.";
    }
  ];

  home.activation.nucleusWallpaperProvision = lib.hm.dag.entryAfter [ "nucleusKeyProvision" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    export HOME="${config.home.homeDirectory}"

    picturesDir="$HOME/Pictures/wallpapers"

    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    mkdir -p "$picturesDir"

    # nucleus_decrypt_wallpaper SOURCE DEST
    # Decrypts a SOPS binary blob to DEST.
    # Key priority:
    #   1. Host SSH key — preferred; available after the first boot
    #   2. GPG keyring  — fallback when the host key is not yet present
    # Returns 1 (without writing DEST) when neither key source is usable.
    nucleus_decrypt_wallpaper() {
      if [ -f "${hostSshKeyPath}" ]; then
        SOPS_AGE_SSH_PRIVATE_KEY_FILE="${hostSshKeyPath}" \
          ${pkgs.sops}/bin/sops --decrypt --output "$2" "$1" 2>/dev/null \
          && return 0
      fi

      # Abort early when no GPG secret key is available to avoid a confusing
      # SOPS error message.
      if ! ${pkgs.gnupg}/bin/gpg --list-secret-keys --with-colons 2>/dev/null | ${pkgs.gnugrep}/bin/grep -Eq '^(sec|ssb):'; then
        return 1
      fi

      ${pkgs.sops}/bin/sops --decrypt --output "$2" "$1"
    }

    found=0
    for wallpaper_blob in "${wallpapersDir}"/*.sops; do
      [ -e "$wallpaper_blob" ] || continue
      found=1

      targetFile="$picturesDir/$(basename "${wallpaper_blob%.sops}")"
      tmpTarget="$(mktemp)"

      if nucleus_decrypt_wallpaper "$wallpaper_blob" "$tmpTarget"; then
        # Only overwrite the target if the content actually changed to avoid
        # unnecessary writes (and to keep the file mtime stable).
        if [ ! -f "$targetFile" ] || ! ${pkgs.diffutils}/bin/cmp -s "$tmpTarget" "$targetFile"; then
          mv "$tmpTarget" "$targetFile"
          chmod 644 "$targetFile"
        else
          rm -f "$tmpTarget"
        fi

      else
        rm -f "$tmpTarget"
        echo "nucleus: failed to decrypt wallpaper $(basename "$wallpaper_blob"); skipping." >&2
      fi
    done

    if [ "$found" -eq 0 ]; then
      echo "nucleus: no wallpaper blobs (*.sops) found in ${wallpapersDir}; skipping wallpaper provisioning."
    fi

    # Stale cleanup: remove decrypted files that no longer have a matching
    # .sops source so the gallery does not show deleted assets.
    for decryptedFile in "$picturesDir"/*; do
      [ -e "$decryptedFile" ] || continue
      case "$decryptedFile" in *.xml) continue;; esac
      baseName="$(basename "$decryptedFile")"
      if [ ! -e "${wallpapersDir}/$baseName.sops" ]; then
        rm -f "$decryptedFile"
        echo "nucleus: removed stale wallpaper $baseName (no matching .sops source)."
      fi
    done

    # Apply gallery / slideshow mode.
    # macOS: point System Events at the wallpapers folder and enable rotation
    #        (picture rotation=1, 10-minute interval, random order).
    # GNOME: generate nucleus-gallery.xml listing all decrypted images, then
    #        point picture-uri at the XML file.  Each image displays for 595 s
    #        with a 5 s overlay transition (600 s / 10 min total per slide).
    if command -v osascript >/dev/null 2>&1; then
      osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
    set theDesktops to desktops
    repeat with aDesktop in theDesktops
        set picture rotation of aDesktop to 1
        set change interval of aDesktop to 600.0
        set random order of aDesktop to true
        set picture of aDesktop to POSIX file "$picturesDir"
    end repeat
end tell
EOF
    elif command -v gsettings >/dev/null 2>&1; then
      xmlFile="$picturesDir/nucleus-gallery.xml"
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

      if [ -n "$firstImg" ]; then
        {
          printf '<?xml version="1.0" encoding="UTF-8"?>\n'
          printf '<background>\n'
          cat "$tmpXml"
          printf '  <transition type="overlay">\n    <duration>5.0</duration>\n    <from>%s</from>\n    <to>%s</to>\n  </transition>\n' \
            "$prevImg" "$firstImg"
          printf '</background>\n'
        } > "$xmlFile"
        gsettings set org.gnome.desktop.background picture-uri "file://$xmlFile" >/dev/null 2>&1 || true
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$xmlFile" >/dev/null 2>&1 || true
      fi
      rm -f "$tmpXml"
    fi
  '';
}
