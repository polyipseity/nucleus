# modules/wallpapers.nix — Home Manager activation hook that decrypts SOPS-
# encrypted wallpaper blobs and sets the active desktop background.
#
# Asset layout: assets/wallpapers/*.sops — each file is a binary image
# encrypted with SOPS (age via host SSH key or GPG fallback).  On activation
# the blobs are decrypted into ~/Pictures/wallpapers/ and the first one is
# applied as the desktop wallpaper on both macOS (osascript) and GNOME (gsettings).
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
    # Tracks the first successfully decrypted wallpaper path; used for the
    # desktop background update at the end of the loop.
    activeWallpaperPath=""

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

        # Record the first wallpaper path; used below to set the background.
        if [ -z "$activeWallpaperPath" ]; then
          activeWallpaperPath="$targetFile"
        fi
      else
        rm -f "$tmpTarget"
        echo "nucleus: failed to decrypt wallpaper $(basename "$wallpaper_blob"); skipping." >&2
      fi
    done

    if [ "$found" -eq 0 ]; then
      echo "nucleus: no wallpaper blobs (*.sops) found in ${wallpapersDir}; skipping wallpaper provisioning."
    fi

    # Apply the first decrypted wallpaper as the desktop background.
    # osascript path: macOS (applies to every Space / desktop).
    # gsettings path: GNOME on Linux.
    if [ -n "$activeWallpaperPath" ]; then
      if command -v osascript >/dev/null 2>&1; then
        osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
  repeat with desktopRef in desktops
    set picture of desktopRef to POSIX file "$activeWallpaperPath"
  end repeat
end tell
EOF
      elif command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.background picture-uri "file://$activeWallpaperPath" >/dev/null 2>&1 || true
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$activeWallpaperPath" >/dev/null 2>&1 || true
      fi
    fi
  '';
}
