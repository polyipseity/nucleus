---
description: "Use when adding, modifying, or reviewing runtime configuration for nucleus services. Covers the nucleus-config CLI usage, config.json schema, and how services consume runtime toggles."
name: "nucleus-config Runtime Configuration"
applyTo: "scripts/nucleus-config.*, src/**/*camilladsp*"
---

# nucleus-config Runtime Configuration

## Config file location

`~/.local/state/nucleus/config.json`

This path is intentionally outside `~/.config/` (which is managed by Home Manager / DSC) so changes survive rebuilds/reapplies.

Default (file absent or key missing) = enabled for all toggles.

## CLI usage

```sh
nucleus-config get [<section.key>]   # Print config value(s). Omit key to dump all.
nucleus-config set <section.key> <val>  # Set a config key (value is JSON-typed).
nucleus-config list                  # Print all config as flat key=value pairs.
```

The `set` subcommand tries to parse the value as JSON (`true`, `false`, numbers) before falling back to string. So:
- `nucleus-config set camilladsp.heartbeat false` → stores `false` as boolean
- `nucleus-config set some.section "hello"` → stores `"hello"` as string

## Schema

```json
{
  "camilladsp": {
    "heartbeat": true
  }
}
```

Only runtime toggles live here — things you want to change without a rebuild/reapply.

## Adding a new toggle

1. Document the key path in this file.
2. Update the consuming code to read the config file and check the key (defaulting to `true`).
3. The CLI handles the file transparently — no changes needed unless adding new subcommands.

## How services consume the config

Services read `config.json` directly rather than shelling out to `nucleus-config`, so they work even when `nucleus-config` is unavailable (e.g. early boot before Nix finishes deploying).

POSIX pattern (shell):
```sh
config_json="${HOME}/.local/state/nucleus/config.json"
enabled=true
if [ -f "$config_json" ]; then
  val=$(jq -r '.section.key // true' "$config_json")
  if [ "$val" = "false" ]; then enabled=false; fi
fi
if [ "$enabled" = "true" ]; then
  # heartbeat loop or feature
fi
```

Windows pattern (PowerShell):
```powershell
$configFile = Join-Path $HOME ".local\state\nucleus\config.json"
$enabled = $true
if (Test-Path $configFile) {
  $cfg = Get-Content -Raw $configFile | ConvertFrom-Json
  if ($null -ne $cfg.section.key -and -not $cfg.section.key) {
    $enabled = $false
  }
}
if ($enabled) {
  # heartbeat loop or feature
}
```
