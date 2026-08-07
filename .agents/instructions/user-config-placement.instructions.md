---
description: "Use when deciding whether a config belongs in src/modules/configs/ or src/users/, or when wiring per-user homedir overlay selectors."
name: "User Config Placement"
applyTo: "src/modules/configs/**, src/users/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/modules/**/*.ps1, AGENTS.md"
---

## Placement taxonomy

### Machine-wide singleton — `src/modules/configs/`

One configuration location for the entire host. Adding a second managed nucleus user does not require a second repo file. Examples: system gitconfig, camilladsp, camillagui-backend, replica-gc.json, ssh/sshd, VM templates.

### Per-user homedir — `src/users/default/` + `src/users/<username>/`

One config instance per OS user via homedir symlink. `default/` is the fallback template; `<username>/` wins when present. Symlink-per-user deployment always belongs here, even when all users currently share identical content via `default/`.

### Registry domains — `src/users/default/*.json`

Structured nucleus data (`profile.json`, `cloud-drives.json`, …) assembled by `users-registry.nix`. Same per-user-over-default merge semantics as app trees, but loaded via the registry loaders — not third-party app files.

### Dual-scope apps

Split explicitly when an app supports both machine-wide and per-user scopes. Git is canonical: system scope in `src/modules/configs/git/`, user scope in `src/users/default/git/`.

## Overlay coverage rule

Every app tree under `src/users/` MUST be consumed only through overlay selectors — never via a hardcoded `src/users/default/...` path in deployment code.

| Mechanism | POSIX | Windows | Shell scripts |
|-----------|-------|---------|---------------|
| Host-specific file | `mkUserOverlay` → `selectSource` | `Resolve-UserConfigSource` | N/A |
| Single file | `mkUserOverlay` → `selectFile` | `Resolve-UserConfigFile` / `Deploy-UserWritableSymlink` | `resolve-user-config.sh` |
| Directory tree | `mkUserOverlay` → `selectDir` | `Resolve-UserConfigDir` | `resolve_user_config_dir` |
| Registry JSON | `users-registry.nix` | `Load-UserRegistry.ps1` | `load-user-registry.sh` |

Allowed hardcoded `src/users/default/` references: inside the selector implementations themselves, registry loaders, and tests that assert default baseline content.

## Anti-patterns

- Per-user homedir config in `src/modules/configs/` (blocks multi-user overlay; shared symlink collisions).
- Hardcoded `src/users/default/...` in deployment modules or activation scripts.
- Duplicate file in both `configs/` and `users/`.
- Mixing machine and user scope in one directory tree.

## Related instructions

- `app-config-policy.instructions.md` — deployment methods (writable symlink, merge, runtime read) within each scope.
- `git-scope-terminology.instructions.md` — dual-scope git reference implementation.
