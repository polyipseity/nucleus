# NixOS activation setup helpers.
# Each section is guarded by an env var check; only the relevant section
# activates based on which env var the Nix wrapper sets.
# This file is sourced by multiple activation scripts in:
#   src/hosts/NixOS/activation.nix
#   src/hosts/NixOS/desktop.nix

# ---- nvimLauncher ----------------------------------------------------------
# Creates a deterministic symlink at /etc/nucleus-bin/nvim that
# vscode-neovim can use (the extension does not expand ${userHome} or ~).
# Resolves the nvim path from the home-manager profile directory so that no
# username is hardcoded, matching Home Manager's useUserPackages = true layout.
# Expects env var: NUCLEUS_NVIM_PATH
if [ -n "${NUCLEUS_NVIM_PATH:-}" ] && [ -x "$NUCLEUS_NVIM_PATH" ]; then
  mkdir -p /etc/nucleus-bin
  ln -sfn "$NUCLEUS_NVIM_PATH" /etc/nucleus-bin/nvim
fi

# ---- ensureLogDirs ---------------------------------------------------------
# Create system log directories for all nucleus systemd services before they
# start, so journald/stderr redirect targets exist on disk.
# Expects env vars: NUCLEUS_SYSTEM_LOG_DIR, NUCLEUS_LOG_SUBDIRS
if [ -n "${NUCLEUS_SYSTEM_LOG_DIR:-}" ]; then
  for subdir in $NUCLEUS_LOG_SUBDIRS; do
    mkdir -p "$NUCLEUS_SYSTEM_LOG_DIR/$subdir"
  done
fi

# ---- verifyNucleusServices -------------------------------------------------
# Warn-only check that all managed services are running after activation.
# Failing to start a service should not block activation, but the warning
# surfaces issues for post-apply investigation.
if command -v nucleus-svc >/dev/null 2>&1; then
  if ! nucleus-svc verify; then
    echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
  fi
fi

# ---- disableSteamAutostart -------------------------------------------------
# Suppress Steam autostart: Steam creates ~/.config/autostart/steam.desktop
# when the user toggles "Start Steam on login" inside the application.
# This activation script removes the file on every rebuild so the declarative
# config overrides that runtime preference.
# Cross-platform parity:
#   macOS   — login item removal in MacBook/activation.nix (osascript)
#   NixOS   — this activation script
#   Windows — Disable-SteamAutoStartup module + apply.ps1
# undoc-supp: steam autostart entry may not exist on first install;
# best-effort cleanup that should not abort activation.
find /home -maxdepth 3 -path '*/autostart/steam.desktop' -delete 2>/dev/null || true  # undoc-supp: steam autostart entry may not exist on first install; best-effort cleanup that should not abort activation.
