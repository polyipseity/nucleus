# Project guidelines

Inspect the tree before assuming files, tests, or commands. Keep this file short: file rules in `.agents/instructions/*.instructions.md`, workflows in `.agents/prompts/*.prompt.md`, skills in `.agents/skills/<skill>/`. No `docs/`; never add `.github/copilot-instructions.md`.

## Repository shape

- `src/`: `flake.nix` beside `flake.lock`, `hosts/<Host>/`, `platforms/<Platform>/`, `modules/`, `scripts/`, `users/`.
- `src/hosts/<Host>/`: host deployment (MacBook and NixOS flake configs, Windows `apply.ps1` plus DSC YAML, `<Host>/scripts/`). Hosts: `MacBook`, `NixOS`, `Windows`. Platform keys: `macOS`, `NixOS`, `Windows` (`host-platform-registry.json`).
- `src/platforms/<Platform>/`: shared Home Manager modules, activation scripts, Windows PowerShell modules.
- `src/modules/`: cross-host Nix, single-file modules preferred; `src/modules/env/` is the one directory module. Exceptions: `src/modules/configs/` (machine-wide singletons with host variants), `src/users/` (per-user overlays). See `user-config-placement.instructions.md`, `app-config-policy.instructions.md`.
- `src/users/`: registry JSON (`<username>/<domain>.json` with `default/` and co-located schemas), per-user app trees, assembly via `users-registry.nix`, `load-user-registry.sh`, `Load-UserRegistry.ps1`. Deep merge with `lib.recursiveUpdate`; arrays replace wholesale.
- `scripts/`: user-facing `nucleus-*` commands, each `.sh`/`.ps1`. `src/scripts/`: Nix-internal tooling by domain. See `script-authoring.instructions.md`, `nucleus-apps.instructions.md`.
- `tests/` mirrors `src/`, uses `tests/fixtures/`, never couples to real users (`testing.instructions.md`).
- `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`; `.opencode/commands/` mirrors `.agents/prompts/`. Automation in `.github/`; formatting in `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`, `.agents/.markdownlint.jsonc`.

## Build and validation

- Discover commands in the repo. See `tooling-and-validation.instructions.md`.
- Every external tool used by `check.sh` or `check.ps1` is declared in preflight; missing tools hard-fail.
- Every JSON and YAML data file needs inline `$schema` pointing at its co-located schema. JSONC with an embedded one is exempt.
- `cargo-nextest` is the managed Rust runner; limits in `src/users/default/nextest/config.toml`.
- Declare each `nucleus-*` command once in `mkNucleusApps` (`src/flake.nix`); PATH, `nix run`, and `packages` derive from it. No second registration.
- `nucleus-bootstrap` installs Nix and base deps only and never depends on apply; it may call apply via `--apply`/`-Apply` after deps exist.
- Never filter or truncate `nucleus-apply` output: capture stdout and stderr, ignore the direnv dump at the end, and on non-zero exit read the last activation step instead of rerunning.
- Nix is unavailable on Windows: keep Nix changes small and isolated, lean on CI.
- Temporary nixpkgs overrides use `nixpkgs-next` in `src/modules/packages/nixpkgs-overrides.nix`; see `nixpkgs-overrides.instructions.md`.

## Core conventions

- Prefer declarative state.
- Config deployment priority: writable symlink > read-only > merge > runtime direct read (`app-config-policy.instructions.md`). Deviations need a code comment.
- Git scope: "global" is `git --system`, "user" is `git --global`; never use "global" for `--global` (`git-scope-terminology.instructions.md`).
- Share POSIX behavior in shared modules. Windows uses PowerShell, POSIX uses bash, never bash on Windows; parity across all three hosts comes first (`cross-host-feature-parity.instructions.md`).
- Centralize daemon and service restarts per OS; restart each daemon at most once per activation.
- Services are persistent daemons by default; firing policy is in `.agents/skills/nucleus-service-reference/references/service-firing-policy.md`.
- `lockfile.json` must not duplicate `flake.lock`; `suggestions.vscode` is the sole exception. See `lockfile-enforcement.instructions.md`.
- Sort unordered lists alphabetically; preserve semantic or load order. Service lists stay hand-written in declared order (alphabetical by name, PDF presets quality-descending), never auto-sorted.
- Sentence case for user-facing labels (`documentation.instructions.md`). YAML uses `.yml`, except required `.sops.yaml`.
- Prefer preview, beta, or canary; stable needs `# WHY:`.
- Do not hide meaningful errors (`2>/dev/null`, `|| true`, `-ErrorAction SilentlyContinue`) unless expected, justified, and still checked.
- Pause below 1% free space or on out-of-space error; search only inside the task target (`resource-boundaries.instructions.md`).
- Output: `output-handling.instructions.md`. Annotations: `comment-annotations.instructions.md`. Privileges: hard error in `src/`, escalation in `scripts/` (`script-authoring.instructions.md`). Packages: `package-installation-scope.instructions.md`. Host scope: `host-filesystem-scope.instructions.md`. Tests: `testing.instructions.md`. Runner: `step-runner.instructions.md`.
- Shared state flows through the step-runner context, never ambient scope.

## Directory roots

- At most two native roots per host, one USER and one SYSTEM. Each user gets `~/.nucleus` (`%USERPROFILE%\.nucleus`) with `user`/`system` symlinks; `clouds`, `dev`, `Downloads` stay as-is.
- macOS: USER `~/Library/Application Support/nucleus`, SYSTEM `/Library/Application Support/nucleus`. NixOS: USER `~/.local/share/nucleus`, SYSTEM `/var/lib/nucleus`. Windows: USER `%LOCALAPPDATA%\nucleus`, SYSTEM `%ProgramData%\nucleus`.
- Code references only roots. Services write `<root>/logs`, `<root>/state`, `<root>/config`, `<root>/run`, `<root>/caddy`; activation creates root-to-conventional links, never service code.
- Symlinks: `~/.nucleus` → roots → conventional targets, never reversed. `~/.nucleus` is not a data root and services never write there.
- Not roots: `/usr/local/*`, `/nix`, `%USERPROFILE%\.agents`, `/run/secrets`, `C:\ProgramData\ssh`, scheduled-task registry env vars, `/etc/nucleus/bin`.

## Boundaries and invariants

"Only plan", "only research", "do not edit files" lock the turn: no edits, file creation, implementation commands, or `/implement-plan`; only the session-memory plan file is exempt. Owner triggers live in user-scope `standing-orders.instructions.md` from `src/users/default/agents/instructions/`; read it before the first tool call. A boundary locks until lifted, forbids repository writes, makes git opt-in per operation, and batches questions into the final report.

- No shims, deprecation layers, migration glue, aliases, fallbacks, or compat wrappers. Rename, restructure, or remove in one commit and fix downstream consumers then. If a compat layer is unavoidable, keep it smaller and local.
- No migration logic in permanent code: update references in the breaking commit, run host cleanup before merging, and keep one-off steps out of the repo.
- `MANUAL.md` is ongoing operations only, never migration runbooks.
- macOS lock hardening stays on (`askForPassword = true`, `askForPasswordDelay = 0`); Windows DSC keeps `LongPathsEnabled = 1`.
- Manual host instructions stay as activation-tail output; dev-repo provisioning follows secrets and key materialization on POSIX and Windows.
- Wallpapers come from managed decrypted assets, never ad-hoc local files.
- SOPS recipients stay real and shared; rewrap with `sops updatekeys` after recipient changes. A missing Jellyfin admin token is a hard error, not a gating case.
- Verify target paths and list files before edits; check imports, `readFile`, and dot-sourcing when adding fragments. Map all cross-references before editing.
- Keep reusable Windows PowerShell in `src/platforms/Windows/modules/` and `src/hosts/Windows/apply.ps1` orchestration-focused.
- Root `.gitignore` is a hard invariant: never edit, stage, or remove it; escalate. User-scope ignore files symlink to `~/.config/git/ignore`; other `.gitignore` files need explicit request. Remove build pollution immediately.
