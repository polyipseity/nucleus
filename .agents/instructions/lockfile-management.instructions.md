---
description: "Use when managing or editing the consolidated lockfile at src/lockfiles/. Covers lockfile structure, rationale for custom vs native lockfiles, per-section semantics, and operational update commands."
name: "Lockfile Management"
applyTo: "src/lockfiles/**"
---

# Lockfile Management

The repository uses a consolidated lockfile at `src/lockfiles/lockfile.json` to pin tool and package versions across all package managers. This provides a single source of truth for reproducible environments.

## When a package manager has no native lockfile

Some package managers don't generate a lockfile natively. In that case, pin versions directly in `lockfile.json` under the appropriate key.

### Homebrew: no native Brewfile.lock.json

Homebrew's `brew bundle` command has no native lockfile (confirmed: no `--lockfile` flag, dead `no_lock` parameter, zero search results).

Homebrew formula, cask, and Mac App Store version pins live under the `homebrew` key in `lockfile.json`:

```json
{
  "homebrew": {
    "brews": { "formula-name": "1.2.3" },
    "casks": { "cask-name": "4.5.6" },
    "masApps": { "AppName": "app-store-id" }
  }
}
```

Consumed by:

- **nix-darwin activation**: `homebrew.nix` sets `onActivation.autoUpdate = false` and `onActivation.upgrade = false` so Homebrew respects installed versions. Activation runs `brew bundle --force` from nix-darwin's generated Brewfile, which installs whatever versions are currently in the local cellar. The lockfile provides the audit trail for what versions should be present.

- **check scripts**: `scripts/check.sh` and `scripts/check.ps1` validate the homebrew section existence and non-emptiness in lockfile validation.

## Schema

The lockfile follows `lockfile.schema.json` (JSON Schema Draft-07). Each top-level key corresponds to a package manager:

| Key              | Format                          | Description                              |
| ---------------- | ------------------------------- | ---------------------------------------- |
| `$schema`        | string                          | Path to schema file                      |
| `version`        | integer                         | Lockfile format version                  |
| `updated`        | ISO 8601 timestamp              | Last update timestamp                    |
| `scoop`          | string → string                 | Scoop package name → version             |
| `cargo-binstall` | string → string                 | Cargo crate name → version               |
| `bun`            | string → string                 | Bun package name → version               |
| `uv`             | string → string                 | Uv package name → version                |
| `rustup`         | string → string                 | Rust toolchain → date                    |
| `winget`         | string → string                 | WinGet package ID → version              |
| `vscode`         | string → string                 | VS Code extension ID → version           |
| `homebrew`       | object with brews/casks/masApps | Homebrew formula/cask/MAS name → version |
| `ollama`         | string → string                 | Ollama model name → digest hash          |

All sections are required but may be empty (`{}`).
