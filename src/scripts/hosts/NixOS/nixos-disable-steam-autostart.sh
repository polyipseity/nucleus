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
