# macbook manual steps

- BetterDisplay: grant Accessibility + Screen Recording in System Settings > Privacy & Security.
- Battery: open battery.app once and complete setup so `/usr/local/bin/battery` is installed.
- Chrome Remote Desktop: visit <https://remotedesktop.google.com/access> to name this Mac and set a PIN.
- Chrome Remote Desktop: grant Screen Recording + Accessibility to `ChromeRemoteDesktopHost`.
- nix-index: run `nix-index` once after first activation to build the file-index database. This is required for pay-respects to suggest `nix profile install` commands when an unknown command is typed. Re-run periodically (e.g. weekly) to keep the index current with nixpkgs updates.
- Power button: System Settings → General → Shutdown Behavior → set "When I press the power button" to **Sleep** (not Shut Down). This cannot be set via pmset; it is a user preference managed by the OS.
