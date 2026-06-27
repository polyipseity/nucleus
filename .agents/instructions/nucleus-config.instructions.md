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

Services read `config.json` directly (not via `nucleus-config`) so they work during early boot. Both POSIX and Windows follow the same pattern: read file, default `section.key` to `true`.

**POSIX** (shell — uses `jq`):
```sh
config_json="${HOME}/.local/state/nucleus/config.json"
enabled=true
[ -f "$config_json" ] && enabled=$(jq -r '.section.key // true' "$config_json")
if [ "$enabled" = "true" ]; then
  # run feature
fi
```

**Windows** (PowerShell — uses `ConvertFrom-Json`):
```powershell
$configFile = Join-Path $HOME ".local\state\nucleus\config.json"
$enabled = $true
if (Test-Path $configFile) {
  $cfg = Get-Content -Raw $configFile | ConvertFrom-Json
  $enabled = if ($null -eq $cfg.section.key) { $true } else { $cfg.section.key }
}
if ($enabled) { /* run feature */ }
```
