#!/usr/bin/env sh
# Apply the nucleus configuration for this host.
# Run via:  nix run ./src#apply
# Or:       sh src/scripts/apply.sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
NIX_EXTRA_FEATURES="nix-command flakes"
HOST_SSH_KEY_PATH="/etc/ssh/ssh_host_ed25519_key"
SECRETS_DIR="$REPO_ROOT/src/secrets"
WALLPAPERS_DIR="$REPO_ROOT/src/assets/wallpapers"
WALLPAPER_OUTPUT_DIR="$HOME/Pictures/wallpapers"
ACTIVE_WALLPAPER_PATH=""

log_stage() {
  printf '\n==> [Stage %s/4] %s\n' "$1" "$2"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: required command '$1' is not available" >&2
    exit 1
  fi
}

decrypt_json() {
  source_path="$1"
  output_path="$2"

  if [ -f "$HOST_SSH_KEY_PATH" ]; then
    if SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOST_SSH_KEY_PATH" \
      sops --decrypt --output-format json "$source_path" >"$output_path" 2>/dev/null; then
      return 0
    fi
  fi

  sops --decrypt --output-format json "$source_path" >"$output_path"
}

decrypt_blob() {
  source_path="$1"
  output_path="$2"

  if [ -f "$HOST_SSH_KEY_PATH" ]; then
    if SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOST_SSH_KEY_PATH" \
      sops --decrypt --output "$output_path" "$source_path" 2>/dev/null; then
      return 0
    fi
  fi

  if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -Eq '^(sec|ssb):'; then
    return 1
  fi

  sops --decrypt --output "$output_path" "$source_path"
}

run_preflight_checks() {
  require_command git
  require_command gpg
  require_command jq
  require_command nix
  require_command sops

  if [ ! -f "$REPO_ROOT/src/flake.nix" ]; then
    printf '%s\n' "error: flake file not found at $REPO_ROOT/src/flake.nix" >&2
    exit 1
  fi

  case "$(uname -s)" in
    Darwin)
      target="macbook"
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        require_command sudo
        target="nixos"
      else
        target="${NUCLEUS_USERNAME:-$(id -un)}"
      fi
      ;;
    *)
      printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "Target flake profile: $REPO_ROOT/src#$target"
  printf '%s\n' "Targeted secret files: $SECRETS_DIR/*.yml"
  printf '%s\n' "Targeted wallpaper blobs: $WALLPAPERS_DIR/*.sops"
}

materialize_secrets() {
  if [ ! -d "$SECRETS_DIR" ]; then
    printf '%s\n' "nucleus: no secrets directory found at $SECRETS_DIR; skipping secret provisioning."
    return
  fi

  mkdir -p "$HOME/.gnupg" "$HOME/.ssh"
  chmod 700 "$HOME/.gnupg" "$HOME/.ssh"

  found=0
  for secrets_file in "$SECRETS_DIR"/*.yml; do
    [ -e "$secrets_file" ] || continue
    found=1

    tmp_json="$(mktemp)"

    if decrypt_json "$secrets_file" "$tmp_json"; then
      jq -c '.ssh_keys[]?' "$tmp_json" | while IFS= read -r entry; do
        key_name="$(printf '%s' "$entry" | jq -r '.name')"
        key_path="$HOME/.ssh/$key_name"
        key_value="$(printf '%s' "$entry" | jq -r '.value')"

        if [ ! -f "$key_path" ] || [ "$(cat "$key_path" 2>/dev/null || true)" != "$key_value" ]; then
          printf '%s\n' "$key_value" >"$key_path"
          chmod 600 "$key_path"
        fi
      done

      tmp_gpg="$(mktemp)"
      jq -r '.gpg_imports[]?.value' "$tmp_json" >"$tmp_gpg"
      if [ -s "$tmp_gpg" ]; then
        gpg --batch --import "$tmp_gpg" >/dev/null 2>&1 || true
      fi
      rm -f "$tmp_gpg"
    else
      printf '%s\n' "nucleus: failed to decrypt $(basename "$secrets_file"); skipping." >&2
    fi

    rm -f "$tmp_json"
  done

  if [ "$found" -eq 0 ]; then
    printf '%s\n' "nucleus: no .yml secret files found in $SECRETS_DIR; skipping secret provisioning."
  fi
}

materialize_wallpapers() {
  if [ ! -d "$WALLPAPERS_DIR" ]; then
    printf '%s\n' "nucleus: no wallpaper assets directory found at $WALLPAPERS_DIR; skipping wallpaper sync."
    return
  fi

  mkdir -p "$WALLPAPER_OUTPUT_DIR"

  found=0
  for wallpaper_blob in "$WALLPAPERS_DIR"/*.sops; do
    [ -e "$wallpaper_blob" ] || continue
    found=1

    output_name="$(basename "$wallpaper_blob" .sops)"
    output_path="$WALLPAPER_OUTPUT_DIR/$output_name"
    tmp_target="$(mktemp)"

    if decrypt_blob "$wallpaper_blob" "$tmp_target"; then
      if [ ! -f "$output_path" ] || ! cmp -s "$tmp_target" "$output_path"; then
        mv "$tmp_target" "$output_path"
        chmod 644 "$output_path"
      else
        rm -f "$tmp_target"
      fi

      if [ -z "$ACTIVE_WALLPAPER_PATH" ]; then
        ACTIVE_WALLPAPER_PATH="$output_path"
      fi
    else
      rm -f "$tmp_target"
      printf '%s\n' "nucleus: failed to decrypt wallpaper $(basename "$wallpaper_blob"); skipping." >&2
    fi
  done

  if [ "$found" -eq 0 ]; then
    printf '%s\n' "nucleus: no wallpaper blobs (*.sops) found in $WALLPAPERS_DIR; skipping wallpaper sync."
  fi
}

run_secret_materialization() {
  materialize_secrets
  materialize_wallpapers
}

apply_configuration() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "Applying nix-darwin configuration: macbook"
      nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
        run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        printf '%s\n' "Applying NixOS configuration: nixos"
        sudo nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
          run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      else
        target_username="${NUCLEUS_USERNAME:-$(id -un)}"
        printf '%s\n' "Applying Home Manager profile: $target_username"
        nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
          run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      fi
      ;;
    *)
      printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
      exit 1
      ;;
  esac
}

run_post_apply_triggers() {
  case "$(uname -s)" in
    Darwin)
      if [ -n "$ACTIVE_WALLPAPER_PATH" ] && command -v osascript >/dev/null 2>&1; then
        osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
  repeat with desktopRef in desktops
    set picture of desktopRef to POSIX file "${ACTIVE_WALLPAPER_PATH}"
  end repeat
end tell
EOF
      fi
      ;;
    Linux)
      if [ -n "$ACTIVE_WALLPAPER_PATH" ] && command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.background picture-uri "file://$ACTIVE_WALLPAPER_PATH" >/dev/null 2>&1 || true
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$ACTIVE_WALLPAPER_PATH" >/dev/null 2>&1 || true
      fi
      ;;
  esac

  printf '%s\n' "Post-apply trigger: open a new shell session to pick up refreshed environment variables."
}

log_stage 1 "Pre-flight checks"
run_preflight_checks

log_stage 2 "Secret materialization"
run_secret_materialization

log_stage 3 "Primary apply"
apply_configuration

log_stage 4 "Post-apply triggers"
run_post_apply_triggers
