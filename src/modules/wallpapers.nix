{ config, lib, pkgs, ... }:
let
  hostSshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  wallpapersDir = ../../assets/wallpapers;
in
{
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
    activeWallpaperPath=""

    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    mkdir -p "$picturesDir"

    nucleus_decrypt_wallpaper() {
      if [ -f "${hostSshKeyPath}" ]; then
        SOPS_AGE_SSH_PRIVATE_KEY_FILE="${hostSshKeyPath}" \
          ${pkgs.sops}/bin/sops --decrypt --output "$2" "$1" 2>/dev/null \
          && return 0
      fi

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
        if [ ! -f "$targetFile" ] || ! ${pkgs.diffutils}/bin/cmp -s "$tmpTarget" "$targetFile"; then
          mv "$tmpTarget" "$targetFile"
          chmod 644 "$targetFile"
        else
          rm -f "$tmpTarget"
        fi

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
