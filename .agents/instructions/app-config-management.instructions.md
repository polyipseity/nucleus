---
description: "Use when adding or modifying application settings and configurations. Covers storage location selection, per-user override patterns, cross-platform parity, and testing requirements."
name: "App Configuration Management"
applyTo: "src/modules/**/*.nix, src/modules/configs/**, src/hosts/windows/modules/*.ps1, src/flake.nix, src/hosts/windows/users.json, tests/nix/*-tests.nix"
---

# App Configuration Management

This instruction covers how to add, modify, and maintain application settings across **nucleus** while ensuring
per-user overrides, cross-platform parity, and proper test coverage.

## Storage Location Rule (Critical)

Choose app config storage **based on how the app reads it**, not on arbitrary preference:

### 1. Separate JSON File (App reads JSON directly)

Use a separate JSON file under `src/modules/configs/<appname>/` **only if** the app itself reads from that file:

- **LinearMouse** (`src/modules/configs/linearmouse/linearmouse.json`): LinearMouse reads `.config/linearmouse/linearmouse.json` on
  Linux/macOS and `%APPDATA%\linearmouse\linearmouse.json` on Windows.
  - Store settings as JSON.
  - Symlink JSON file to both platform locations from activation (macOS: `src/modules/macos.nix`; Windows: DSC or modules).

- **VS Code** (`src/modules/configs/vscode/`): VS Code reads `settings.json`, `keybindings.json`, `mcp.json`, etc. from
  user config directories.
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

**In `src/hosts/windows/users.json` (Windows users)**:
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

**For Nix-based configurations (macOS/Linux, home.nix)**:

```nix
# Define defaults
appDefaultSettings = {
  key1 = "default_value";
  key2 = true;
};

# Platform-specific overrides (optional)
appPlatformSettings = lib.optionalAttrs pkgs.stdenv.isDarwin {
  key3 = false;  # Override only on macOS
};

# Read user overrides from effectiveUser (injected by flake.nix)
appUserSettings =
  if effectiveUser ? app && effectiveUser.app ? settings then
    effectiveUser.app.settings
  else
    { };

# Merge in order
appManagedSettings = appDefaultSettings // appPlatformSettings // appUserSettings;
```

**For Windows configurations (Sync-AppConfig.ps1)**:

```powershell
function Sync-AppConfig {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Users  # Loaded from Load-UserRegistry.ps1
  )

  foreach ($user in $Users) {
    # Defaults
    $effectiveSettings = $defaults

    # Merge user overrides if present
    if ($user.PSObject.Properties['app'] -and $user.app.settings) {
      $effectiveSettings = Merge-Settings $effectiveSettings $user.app.settings
    }

    # Apply to registry, DSC, or config file
  }
}
```

### Step 3: Update Tests

Add assertions to ensure override fields exist and are wired correctly:

```nix
# tests/nix/app-config-tests.nix
assert builtins.hasAttr "app" windowsUsers.users.polyipseity;
assert builtins.hasAttr "settings" windowsUsers.users.polyipseity.app;
assert containsRegex "app =" flakeText;  # Verify flake.nix defines overrides
assert containsRegex "appDefaultSettings =" homeText;  # Verify defaults in home.nix
true
```

## Cross-Platform Parity

When adding app settings, audit all three hosts:

1. **macOS** (`src/hosts/macbook/`, `src/modules/macos.nix`): Does the app exist? Are settings applied via
   `defaults`, LaunchAgent, or symlinked config?
2. **NixOS** (`src/hosts/nixos/`, `src/modules/linux.nix`): Does the app exist? Are settings applied via INI files,
   systemd, or other mechanisms?
3. **Windows** (`src/hosts/windows/`, `src/hosts/windows/modules/*.ps1`): Does the app exist? Are settings applied via
   registry, DSC YAML, or manifest files?

For each platform where the app exists, ensure:
- Default settings are centrally defined.
- User override fields are present in the user registry (flake.nix or users.json).
- Activation logic applies `defaults // platform_overrides // user_overrides` in the same order.
- Tests assert on all three locations.

If an app exists on only one or two platforms, document why in a `# WHY` comment in code.

## Atomic Commits

When adding a new app config or updating existing ones, group changes atomically:

**For a new app config**:
```
refactor: add <app> settings with per-user override support

- Define <app> defaults in src/modules/home.nix (or config/<app>/ if JSON)
- Add user override fields to flake.nix and users.json
- Implement merge logic in macos.nix / linux.nix / Windows modules
- Add tests to verify override structure and defaults
- Document WHY comment if platform-specific
```

**For moving an existing app from separate storage**:
```
refactor: migrate <app> config from JSON to native format

BREAKING CHANGE: <app> settings now stored in [native format] instead of JSON.

- Move settings from src/modules/configs/<app>/ to Nix/defaults/registry
- Update activation logic to apply merged settings
- Update tests to assert on new storage location
- Rationale: <app> reads from [native format], not JSON
```

## Testing Requirements

All app configs must have corresponding tests:

1. **Nix tests** (`tests/nix/<app>-config-tests.nix`):
   - Assert default values are present and correct.
   - Assert user override fields exist in flake.nix and users.json.
   - Assert platform overrides are correctly wired.

2. **Windows tests** (`tests/windows/nucleus-dsc.Tests.ps1` or dedicated module):
   - Assert registry values are correctly written post-sync.
   - Assert user-specific overrides take precedence over defaults.

3. **CI integration**:
   - Ensure test file is auto-discovered by CI glob pattern or explicitly listed.
   - Run during every PR and push.

## Checklist for Adding a New App Config

- [ ] Determine storage location: separate JSON (if app reads it) or native format?
- [ ] Add defaults: `src/modules/home.nix`, `src/modules/configs/<app>/`, or flake.nix?
- [ ] Add user override fields to `src/flake.nix` and `src/hosts/windows/users.json`.
- [ ] Implement merge logic: `defaults // platform_overrides // user_overrides`.
- [ ] Activate on all three platforms (macOS, NixOS, Windows) or document exceptions with `# WHY`.
- [ ] Add tests: Nix assertions for defaults/overrides; Windows Pester tests for registry values.
- [ ] Update `.github/workflows/ci.yml` if test discovery pattern doesn't auto-include the file.
- [ ] Create atomic commit with rationale in message.
- [ ] Verify `nix flake check`, all tests, and `bootstrap apply` pass end-to-end.

## Related Files

- `src/modules/home.nix`: Central location for cross-platform app activation and settings.
- `src/modules/configs/`: Separate config files for apps that read them directly (LinearMouse, VS Code).
- `src/flake.nix`: User registry with per-user override fields.
- `src/hosts/windows/users.json`: Windows equivalent of flake.nix user registry.
- `src/hosts/windows/modules/Load-UserRegistry.ps1`: Loads users.json and exposes user records to PowerShell.
- `src/modules/macos.nix`, `src/modules/linux.nix`, `src/hosts/windows/apply.ps1`: Platform-specific activation.
- `AGENTS.md`: Repository conventions and invariants for package selection and settings management.

## Key Principle: Configuration Storage ≠ Configuration Format

**Never store config in a format the app doesn't read.**

QtPass is the canonical example: it does not read `.json` files; it reads from `defaults` (macOS), `QSettings` (Linux), and
registry (Windows). Storing config in a separate JSON file was wrong; storing it as a Nix attrset is correct.

When reviewing or adding app configs, always verify: "Does this app actually read from this file or format?"

If not, move the config to the native format the app reads from, keep JSON only for apps that use it directly, and ensure
the pattern is documented in agent instructions.
