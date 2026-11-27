---
description: "Use when deciding whether a config belongs in src/modules/configs/ or src/users/, or wiring per-user overlay selectors."
name: "User Config Placement"
applyTo: "src/modules/configs/**, src/users/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, AGENTS.md"
---

# User config placement

Machine-wide singletons live in `src/modules/configs/`; per-user homedir config lives in `src/users/default/` plus `src/users/<username>/`, with registry JSON and co-located schemas. An app supporting both scopes splits between the trees.

`users-registry.nix` deep-merges with `lib.recursiveUpdate`: user wins, arrays replace wholesale, and host variants are `MacBook`/`NixOS`/`Windows` maps. Only first-level entries participate in the overlay; every tree reaches content through a selector, never a hardcoded `src/users/default/...` path in deployment code. Hardcoded paths belong only in selectors, loaders, and default-baseline tests. Wallpapers split into `encrypted/` SOPS blobs and `wallpapers/` writable symlink images.

Selectors: `selectSource`/`Resolve-UserConfigSource`, `selectFile`/`Resolve-UserConfigFile`, `selectFirstLevelEntry`/`Resolve-UserConfigFirstLevelEntry`, `listFirstLevelEntries`/`Get-UserConfigFirstLevelEntryList`, and registry loaders. Testing uses fixtures or temp dirs, never a production user. Anti-patterns: per-user config in `configs/`, duplicated config, mixed scopes, second-level overrides.

Full table: `.agents/skills/nucleus-platform-reference/references/user-config-placement.md`.
