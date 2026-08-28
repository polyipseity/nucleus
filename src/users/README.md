# User configuration

Per-user settings for home directories and the user registry. `default/` is the shared template; each real user has a sibling directory with overrides.

Registry domains, homedir overlay rules, placement taxonomy, and loader entry points: `.agents/instructions/user-config-placement.instructions.md` and `app-config-policy.instructions.md`.

## Jellyfin union at sync time

`jellyfin.json` follows the same per-user deep merge as other registry domains: each real user's effective payload is `default/jellyfin.json` merged with `src/users/<username>/jellyfin.json` via `lib.recursiveUpdate`, where array fields are replaced wholesale by design (the intended override contract — see `.agents/instructions/user-config-placement.instructions.md` and the `users-registry.nix` docstring). The default file is empty (`accounts: []`, `libraries: []`) but still participates in that merge.

Jellyfin sync on the host is different: `src/scripts/apply.sh` (POSIX) and `src/hosts/Windows/apply.ps1` union every user's merged `accounts` and `libraries` into one shared Jellyfin instance (dedup by account id and library name at sync time). See `src/scripts/services/jellyfin-sync.sh` and the Windows `Sync-Jellyfin*` modules.
