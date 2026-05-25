# Raycast Manual Configuration Guide

This guide documents Raycast settings that **cannot be configured declaratively** via plist/defaults and require manual setup in the Raycast UI.

The **declarative settings** (LaunchAtLogin, Appearance, WindowMode, DeveloperMode, etc.) are managed by the Nix flake and applied automatically via `nucleus apply`. Only the settings below require manual configuration.

## Manual Setup Steps

Open **Raycast Settings** (Cmd+, after launching Raycast) and navigate to each section:

### General Tab

1. **Raycast Hotkey**: Set to `⌘ space` (Command+Space)
   - Note: This is now available since Spotlight's Command+Space hotkey is disabled by the system configuration.

2. **Show Raycast on**: Select `Screen containing mouse`

3. **Menu Bar Icon**: Verified unchecked (matches declarative setting)

### Shortcuts Tab

1. **Clipboard History**: Search for `Clipboard History`, click `Record Hotkey`, then press `⌥⌘C` (Option+Command+C).

### Advanced Tab (Part 1)

1. **Pop to Root Search**: Set to `After 180 seconds`

2. **Escape Key Behavior**: Select `Close window and pop to root`

3. **Auto-switch Input Source**: Set to `—` (dash / disabled / none)

4. **Navigation Bindings**: Select `Vim Style (^J, ^K ^L, ^H)`

5. **Page Navigation Keys**: Select `Square Brackets`

### Advanced Tab (Part 2)

1. **Root Search Sensitivity**: Move slider to `High`

2. **Hyper Key**: Set to `—` (dash / disabled / none)

3. **Favicon Provider**: Verify set to `Raycast` (declaratively managed)

4. **Emoji Skin Tone**: Select light/yellow tone (first option in skin tone picker)

### Advanced Tab (Part 3)

1. **Import/Export**: Optional backup
   - Click `Export` to back up Raycast configuration
   - Store in a safe location for recovery

2. **Window Capture**:
   - Click `Record Hotkey` to set custom hotkey if desired (optional)
   - Verify `Copy to clipboard` is checked (✓)
   - Verify `Show in Finder` is unchecked (☐)

3. **Custom Wallpaper**: Optional
   - Leave unset for default Raycast wallpaper

### Developer Tools (if developing)

1. **Auto-reload on save**: Verify checked ✓ (declaratively managed)

2. **Open Raycast in development mode**: Verify checked ✓ (declaratively managed)

3. Leave other options unchecked unless actively developing

### Proxy & Certificates

1. **Web Proxy**: Verify `Use System Network Settings` is checked ✓ (declaratively managed)

2. **Certificates**: Verify set to `Keychain` (declaratively managed)

---

## Why These Settings Can't Be Declarative

Raycast stores most advanced settings in a local SQLite database (`~/.local/share/com.raycast.macos/` or similar) rather than macOS plist files. This design choice by Raycast means:

- **Plist-settable options** (startup, appearance, developer mode, etc.) are managed declaratively by this Nix configuration.
- **Database-only options** (timeouts, keybindings, search sensitivity) require manual configuration or Raycast API access (not currently feasible for system management).

Future improvements may allow scripting these via Raycast's extensions or CLI if such APIs become available.

---

## Verification

After configuring the settings above:

1. Close and reopen Raycast (Cmd+Space)
2. Test Vim-style navigation: `^J` down, `^K` up, `^L` right, `^H` left
3. Wait 180 seconds of inactivity to see "Pop to Root" behavior
4. Verify Raycast appears on the screen with the mouse pointer (not fixed position)

If any setting doesn't persist after restarting Raycast, check that it was saved (sometimes Raycast requires dismissing the settings window for changes to take effect).
