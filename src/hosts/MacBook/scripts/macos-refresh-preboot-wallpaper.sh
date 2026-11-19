#!/usr/bin/env bash
# Refreshes the macOS pre-login (FileVault/login-window) wallpaper from the
# managed decrypted wallpapers in ~/Pictures/wallpapers.
#
# WHY this fallback exists (Task 7): `launchctl kickstart -k gui/<uid>/com.apple.wallpaper.agent`
# is blocked by System Integrity Protection (exit 150), so wallpaperexportd cannot be
# triggered from userspace; direct writes to the Preboot Wallpapers store bypass that
# export path. This root apply-time writer keeps the Preboot image in sync.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/bash-guard.sh
. "$SCRIPT_DIR/../../../scripts/lib/bash-guard.sh"
bash_guard_require 5 1 macos-refresh-preboot-wallpaper
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# Test/override knobs (all optional):
#   PREFLIGHT_USER        - username to operate on (default: console user)
#   PREFLIGHT_HOME        - home dir for that user (default: derived via dscl)
#   PREFLIGHT_WALLPAPERS_DIR - wallpapers dir (default: $HOME/Pictures/wallpapers)
#   PREFLIGHT_PREBOOT_ROOT   - root to search under (default: /System/Volumes/Preboot)
#   PREFLIGHT_STATE_DIR      - dir for state file (default: /Library/Application Support/nucleus/state)
#   PREFLIGHT_STATE_FILE     - full path to state file (overrides STATE_DIR)
#   PREFLIGHT_TARGET_GUID    - override user GUID
#   PREFLIGHT_VOLUME_UUID    - override; if set, only look under PREBOOT_ROOT/<UUID>/...

resolve_console_user() {
  if [ -n "${PREFLIGHT_USER:-}" ]; then
    printf '%s' "$PREFLIGHT_USER"
    return 0
  fi
  local u
  u="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)" # check-suppress:suppression_doc: /dev/console may be absent; empty result means no console user.
  if [ -z "$u" ] || [ "$u" = "root" ] || [ "$u" = "loginwindow" ]; then
    printf ''
    return 0
  fi
  printf '%s' "$u"
}

resolve_user_home() {
  if [ -n "${PREFLIGHT_HOME:-}" ]; then
    printf '%s' "$PREFLIGHT_HOME"
    return 0
  fi
  local user="$1"
  local home
  home="$(/usr/bin/dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)" # check-suppress:suppression_doc: user record may be missing; caller skips when home is empty.
  printf '%s' "$home"
}

resolve_user_guid() {
  if [ -n "${PREFLIGHT_TARGET_GUID:-}" ]; then
    printf '%s' "$PREFLIGHT_TARGET_GUID"
    return 0
  fi
  local user="$1"
  local guid_line guid
  guid_line="$(/usr/bin/dscl . -read "/Users/${user}" GeneratedUID 2>/dev/null || true)" # check-suppress:suppression_doc: user record may be missing; caller skips when GUID is empty.
  guid="$(printf '%s' "$guid_line" | /usr/bin/sed -n 's/^GeneratedUID:[[:space:]]*//p')"
  printf '%s' "$guid"
}

# Find lexicographically first regular image file (case-insensitive extensions).
find_first_wallpaper_sorted() {
  local dir="$1"
  local f base lower fullpath
  if [ ! -d "$dir" ]; then
    printf ''
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fullpath="$dir/$f"
    [ -f "$fullpath" ] || continue
    base="$f"
    lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
    *.png | *.jpg | *.jpeg | *.webp | *.gif)
      printf '%s' "$fullpath"
      return 0
      ;;
    *) continue ;;
    esac
  done < <(/bin/ls -1 "$dir" 2>/dev/null | /usr/bin/sort)
  printf ''
}

find_preboot_wallpaper_dir() {
  local preboot_root="$1"
  local guid="$2"
  local vol_override="${PREFLIGHT_VOLUME_UUID:-}"
  local d
  if [ -n "$vol_override" ]; then
    d="$preboot_root/$vol_override/var/db/Wallpapers/$guid"
    if [ -d "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
    printf ''
    return 0
  fi
  # Search all volume dirs
  for d in "$preboot_root"/*/var/db/Wallpapers/"$guid"; do
    if [ -d "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  printf ''
}

render_to_1280x832_png() {
  local src="$1"
  local dst="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/preboot-wallpaper.XXXXXX.png")"
  # Crop-to-fill: compute scale to cover 1280x832, resize, then crop center.
  local w h scale_w scale_h scale neww newh
  w="$(/usr/bin/sips -g pixelWidth "$src" 2>/dev/null | /usr/bin/awk '/pixelWidth/ {print $2}')"
  h="$(/usr/bin/sips -g pixelHeight "$src" 2>/dev/null | /usr/bin/awk '/pixelHeight/ {print $2}')"
  if [ -z "$w" ] || [ -z "$h" ] || [ "$w" -le 0 ] 2>/dev/null || [ "$h" -le 0 ] 2>/dev/null; then
    rm -f "$tmp"
    error "failed to read image dimensions from $src"
    return 1
  fi
  # scale = max(1280/w, 832/h)
  scale_w="$(/usr/bin/awk -v W="$w" 'BEGIN{printf "%.10f", 1280.0/W}')"
  scale_h="$(/usr/bin/awk -v H="$h" 'BEGIN{printf "%.10f", 832.0/H}')"
  scale="$(/usr/bin/awk -v a="$scale_w" -v b="$scale_h" 'BEGIN{if(a>=b) print a; else print b}')"
  neww="$(/usr/bin/awk -v W="$w" -v s="$scale" 'BEGIN{v=int(W*s+0.5); if(v<1)v=1; print v}')"
  newh="$(/usr/bin/awk -v H="$h" -v s="$scale" 'BEGIN{v=int(H*s+0.5); if(v<1)v=1; print v}')"
  # First resize to cover
  if ! /usr/bin/sips -s format png -z "$newh" "$neww" "$src" --out "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "sips resize failed for $src"
    return 1
  fi
  # Then crop to 1280x832 from center
  if ! /usr/bin/sips -s format png --cropToHeightWidth 832 1280 "$tmp" --out "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "sips crop failed for $src"
    return 1
  fi
  # Final resample to exact 1280x832 (in case crop behaved oddly)
  if ! /usr/bin/sips -s format png -z 832 1280 "$tmp" --out "$dst" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "sips final resize failed for $src"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    error "macos-refresh-preboot-wallpaper: only supported on macOS"
    exit 1
  fi

  local user home wallpapers_dir preboot_root state_dir state_file
  user="$(resolve_console_user)"
  if [ -z "$user" ]; then
    warn "macos-refresh-preboot-wallpaper: no console user detected (or console user is root/loginwindow); skipping."
    exit 0
  fi

  home="$(resolve_user_home "$user")"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    warn "macos-refresh-preboot-wallpaper: could not resolve home for user $user; skipping."
    exit 0
  fi

  wallpapers_dir="${PREFLIGHT_WALLPAPERS_DIR:-$home/Pictures/wallpapers}"
  preboot_root="${PREFLIGHT_PREBOOT_ROOT:-/System/Volumes/Preboot}"

  if [ -n "${PREFLIGHT_STATE_FILE:-}" ]; then
    state_file="$PREFLIGHT_STATE_FILE"
  else
    state_dir="${PREFLIGHT_STATE_DIR:-/Library/Application Support/nucleus/state}"
    state_file="$state_dir/preboot-wallpaper.sha256"
  fi

  local guid
  guid="$(resolve_user_guid "$user")"
  if [ -z "$guid" ]; then
    warn "macos-refresh-preboot-wallpaper: could not resolve GeneratedUID for user $user; skipping."
    exit 0
  fi

  local src
  src="$(find_first_wallpaper_sorted "$wallpapers_dir")"
  if [ -z "$src" ]; then
    warn "macos-refresh-preboot-wallpaper: no managed wallpaper images found in $wallpapers_dir (expected png/jpg/jpeg/webp/gif); skipping."
    exit 0
  fi

  local preboot_dir
  preboot_dir="$(find_preboot_wallpaper_dir "$preboot_root" "$guid")"
  if [ -z "$preboot_dir" ]; then
    warn "macos-refresh-preboot-wallpaper: no Preboot wallpaper dir found under $preboot_root for GUID $guid; skipping."
    exit 0
  fi

  if [ ! -d "$preboot_dir" ]; then
    warn "macos-refresh-preboot-wallpaper: Preboot dir $preboot_dir is not a directory; skipping."
    exit 0
  fi

  # Compute hash of source file for idempotency gating.
  local src_hash
  src_hash="$(/usr/bin/shasum -a 256 "$src" | /usr/bin/awk '{print $1}')"
  if [ -z "$src_hash" ]; then
    error "macos-refresh-preboot-wallpaper: failed to hash $src"
    exit 1
  fi

  # Check state file
  if [ -f "$state_file" ]; then
    local prev_hash
    prev_hash="$(cat "$state_file" 2>/dev/null || true)" # check-suppress:suppression_doc: unreadable/missing state file means no previous hash.
    if [ "$prev_hash" = "$src_hash" ] && [ -f "$preboot_dir/Wallpaper.png" ]; then
      say "macos-refresh-preboot-wallpaper: Preboot wallpaper already up to date (hash $src_hash)."
      return 0
    fi
  fi

  # Ensure state dir exists
  local state_dir_real
  state_dir_real="$(dirname "$state_file")"
  if [ ! -d "$state_dir_real" ]; then
    mkdir -p "$state_dir_real"
  fi

  local tmp_png
  tmp_png="$(mktemp "$preboot_dir/.preboot-wallpaper.XXXXXX.png")"
  if ! render_to_1280x832_png "$src" "$tmp_png"; then
    rm -f "$tmp_png"
    error "macos-refresh-preboot-wallpaper: failed to render wallpaper to 1280x832 PNG"
    exit 1
  fi
  # Atomic write of Wallpaper.png (same filesystem)
  local target_png="$preboot_dir/Wallpaper.png"
  /bin/chmod 644 "$tmp_png" 2>/dev/null || true # check-suppress:suppression_doc: best-effort mode set on temp file before atomic move.
  if ! /bin/mv -f "$tmp_png" "$target_png"; then
    rm -f "$tmp_png"
    error "macos-refresh-preboot-wallpaper: failed to move rendered wallpaper into place"
    exit 1
  fi

  # Refresh Metadata.plist: preserve if exists, ensure it exists.
  if [ ! -f "$preboot_dir/Metadata.plist" ]; then
    warn "macos-refresh-preboot-wallpaper: Metadata.plist missing in $preboot_dir; leaving absent (Wallpaper.png updated)."
  fi

  # Update state file
  printf '%s\n' "$src_hash" >"$state_file"

  say "macos-refresh-preboot-wallpaper: updated Preboot wallpaper from $(basename "$src") (hash $src_hash)."
}

main "$@"
