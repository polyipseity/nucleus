---
description: "Use when adding or modifying application settings and configurations. Covers storage location selection, per-user override patterns, cross-platform parity, and testing requirements."
name: "App Configuration Management"
applyTo: "src/modules/**/*.nix, src/modules/configs/**, src/hosts/Windows/modules/**/*.ps1, src/flake.nix, src/hosts/Windows/users.json, tests/src/*-tests.nix"
---

# App Configuration Management

## Storage Location Rule (Critical)

Choose app config storage **based on how the app reads it**, not on arbitrary preference:

### 1. Separate JSON File (App reads JSON directly)

Use a separate JSON file under `src/modules/configs/<appname>/` **only if** the app itself reads from that file:

- **LinearMouse** (`src/modules/configs/linearmouse/linearmouse.json`): LinearMouse reads `.config/linearmouse/linearmouse.json` on Linux/macOS and `%APPDATA%\linearmouse\linearmouse.json` on Windows.
  - Store settings as JSON.
  - Symlink JSON file to both platform locations from activation (macOS: `src/modules/macos.nix`; Windows: DSC or modules).

- **VS Code** (`src/modules/configs/vscode/`): VS Code reads `settings.json`, `keybindings.json`, `mcp.json`, etc. from user config directories.
  - Maintain live repo files under `src/modules/configs/vscode/`.
  - Symlink to both `~/.config/Code/User/` (Linux) and `~/Library/Application Support/Code/User/` (macOS).
  - See `src/modules/editors.nix` for implementation details.

### 2. Native Config Format (App does NOT read JSON)

Do **not** store config in JSON if the app does not read JSON files:

- **QtPass**: Reads from `defaults` (macOS), `QSettings`/INI files (Linux/Windows), not JSON.
  - ✗ Wrong: `src/modules/configs/qtpass/settings.json` (app ignores this).
  - ✓ Correct: Store as Nix attrset in `src/modules/home.nix` (qtPassDefaultSettings).
  - Render to platform-native format during activation:
    - macOS: Shell function writes to `defaults` domain via `defaults write`.
    - Linux: Shell function writes to INI file via sed/awk.
    - Windows: PowerShell writes to registry via `reg add`.

- **Future apps**: Apply the same rule: store config in the format the app actually reads from.

## Per-User Override Pattern

All app settings must support per-user overrides. The merge order is:

```
effective_settings = defaults // platform_overrides // user_overrides
```

### Step 1: Define Override Fields in User Registry

**In `src/flake.nix` (Nix primary user)**:

```nix
users = {
  polyipseity = {
    # ... other user config ...

    # App-specific override example (add one for each app with settings)
    qtpass = {
      settings = { };  # Empty by default; user can add overrides
    };
    linearmouse = {
      settings = { };
    };
    vscode = {
      settings = { };
    };
  };
};
```

**In `src/hosts/Windows/users.json` (Windows users)**:

```json
{
  "users": {
    "polyipseity": {
      "homeDirectory": "C:\\Users\\polyipseity",
      "isPrimary": true,
      "qtpass": { "settings": {} },
      "linearmouse": { "settings": {} },
      "vscode": { "settings": {} }
    }
  }
}
```

### Step 2: Implement Merge Logic

Merge order `defaults // platform_overrides // user_overrides` in target-platform syntax:

**Nix** (home.nix):
```nix
appManagedSettings = appDefaultSettings // appPlatformSettings // appUserSettings;
```

**PowerShell** (Sync-AppConfig.ps1):
```powershell
$effectiveSettings = Merge-Settings (Merge-Settings $defaults $platformOverrides) $user.app.settings
```

### Step 3: Update Tests

Add assertions to ensure override fields exist and are wired correctly:

```nix
# tests/src/app-config-tests.nix
assert builtins.hasAttr "app" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.app;
assert containsRegex "app =" flakeText;  # Verify flake.nix defines overrides
assert containsRegex "appDefaultSettings =" homeText;  # Verify defaults in home.nix
true
```

## Cross-Platform Parity

When adding app settings, audit all three hosts:

1. **macOS** (`src/hosts/MacBook/`, `src/modules/macos.nix`): Does the app exist? Are settings applied via `defaults`, LaunchAgent, or symlinked config?
2. **NixOS** (`src/hosts/NixOS/`, `src/modules/linux.nix`): Does the app exist? Are settings applied via INI files, systemd, or other mechanisms?
3. **Windows** (`src/hosts/Windows/`, `src/hosts/Windows/modules/*.ps1`): Does the app exist? Are settings applied via registry, DSC YAML, or manifest files?

For each platform where the app exists, ensure:

- Default settings are centrally defined.
- User override fields are present in the user registry (flake.nix or users.json).
- Activation logic applies `defaults // platform_overrides // user_overrides` in the same order.
- Tests assert on all three locations.

If an app exists on only one or two platforms, document why in a `# WHY` comment in code.

## Checklist for Adding a New App Config

- [ ] Determine storage location: separate JSON (if app reads it) or native format?
- [ ] Add defaults: `src/modules/home.nix`, `src/modules/configs/<app>/`, or flake.nix?
- [ ] Add user override fields to `src/flake.nix` and `src/hosts/Windows/users.json`.
- [ ] Implement merge logic: `defaults // platform_overrides // user_overrides`.
- [ ] Activate on all three platforms (macOS, NixOS, Windows) or document exceptions with `# WHY`.
- [ ] Add tests: Nix assertions for defaults/overrides; Windows Pester tests for registry values.
- [ ] Update `.github/workflows/ci.yml` if test discovery pattern doesn't auto-include the file.
- [ ] Create atomic commit with rationale in message.
- [ ] Verify `nix flake check`, all tests, and `bootstrap apply` pass end-to-end.
