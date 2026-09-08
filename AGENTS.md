# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide canonical reference. Do not add `.github/copilot-instructions.md`.
- `src/` contains Nix-based declarative configuration: `flake.nix`, `hosts/` (per-machine), `platforms/` (per-platform), `modules/` (cross-host shared).
  - `src/flake.lock` sits adjacent to `flake.nix` (Nix requirement). `src/lockfiles/` stores other lockfiles plus a symlinked `flake.lock` copy.
- `src/hosts/<Host>/` — host-specific deployment: flake system config (`MacBook/`, `NixOS/`), Windows `apply.ps1` + DSC YAML, host-only activation scripts (`<Host>/scripts/`).
- `src/platforms/<Platform>/` — platform-specific logic shared across hosts on that OS: Home Manager modules, activation scripts, Windows PowerShell modules. Keys: `macOS`, `NixOS`, `Windows` (from `host-platform-registry.json`).
- `src/modules/` — cross-host shared Nix modules only. Single-file modules preferred; only exception: `src/modules/env/` (centralized env var introspection).
- **Layout exceptions** (not under `hosts/` or `platforms/`): `src/modules/configs/` (machine-wide singleton configs with host-keyed variants) and `src/users/` (per-user overlays). See `user-config-placement.instructions.md` and `app-config-policy.instructions.md`.
- `src/users/` contains per-user overlays: registry domain JSON (`src/users/<username>/<domain>.json` with `src/users/default/` fallback; schemas co-located), per-user homedir app trees, and runtime assembly (`users-registry.nix` / `load-user-registry.sh` / `Load-UserRegistry.ps1`). Domain deep-merge via `lib.recursiveUpdate`; arrays replaced wholesale.
- `scripts/` contains user-facing automation with paired `.sh`/`.ps1` entry points: bootstrap, check, cloud-setup, gc, health-check, replica-sync, replica-reset, update, vm-setup, ai-sync.
- `src/scripts/` contains Nix-internal scripts in domain subdirectories. Placement rules: `nix-and-script-authoring.instructions.md`. Activation blocks: `activation-scripts.instructions.md`.
- `tests/` mirrors `src/` layout. All changes require corresponding tests; see `testing.instructions.md`. Tests must not couple to specific real users; use `tests/fixtures/`.
- No `docs/` directory. Documentation lives in `.agents/instructions/*.instructions.md`, `src/hosts/<Host>/MANUAL.md`, or inline comments.
- Keep this file short. File-type and workflow-specific rules go in `.agents/instructions/*.instructions.md`, reusable workflows in `.agents/prompts/*.prompt.md`, skills in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or commands exist.

## Architecture

- Agent customization is file-driven: `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`; `.opencode/commands/` mirrors prompt workflows for OpenCode.
- Repository automation: `.github/workflows/ci.yml`, `.github/dependabot.yml`, `.commitlintrc.mjs`.
- Formatting: `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`, `.agents/.markdownlint.jsonc`.

## Conventions

### Inline `$schema` for JSON/YAML data files

- Every JSON and YAML data file MUST include an inline `$schema` property pointing to its schema file.
- This replaces editor-level schema mappings so validation works in any editor and CI.
- Schema files live alongside their data files (e.g., `src/modules/VMs.schema.json` for `src/modules/VMs.json`).
- JSONC files that already embed `$schema` do not need additional mappings.

### Pre-flight and check discovery

See `tooling-and-validation.instructions.md`. Every external tool used by `scripts/check.sh` or `scripts/check.ps1` must be declared in the pre-flight block; missing tools hard-fail.

## Build and Validation

### Rust

- `cargo-nextest` is the managed Rust test runner. See `src/users/default/nextest/config.toml` (limitations section) for known issues.

- Discover commands from the repository; never assume a default stack. Check-step taxonomy: `tooling-and-validation.instructions.md`.
- Nucleus command surface is canonical in `nucleus-apps.instructions.md`. Do not add new single-purpose `nucleus-*` PATH commands.
- **Single registration surface:** every nucleus command declared once in `mkNucleusApps` (`src/flake.nix`); PATH, `nix run`, and `packages` all flow from it. Never hand-register in two places.
- **Bootstrap independence:** `nucleus-bootstrap` installs Nix + base deps only and never depends on apply. It may optionally invoke apply via `--apply`/`-Apply` after deps exist.
- Never filter or truncate `nucleus-apply` output. Capture full stdout+stderr. Ignore the direnv dump at the end. If output ends abruptly or exit code is non-zero, do NOT re-run — read the last activation step and diagnose.
- Known upstream caveat: `builtins.derivation`/`options.json` contextless-source warning is upstream; nucleus-fixed for all plist-based derivations via context-preserving string interpolation.

## Testing

- Tests required for feature additions and breaking changes. See `testing.instructions.md`.
- Step-runner framework: `step-runner.instructions.md`. Shared state flows through the context object, never ambient scope.

## Core Conventions

- Host block-level filesystem scope: `host-filesystem-scope.instructions.md`.
- Prefer declarative state over imperative scripts.
- Config deployment priority: `app-config-policy.instructions.md` — writable symlink (default) > read-only > merge > runtime direct read. Deviations require a code comment.
- Git scope: "global" = machine-wide (`git --system`), "user" = per-user (`git --global`). Never use "global" for `--global`. See `git-scope-terminology.instructions.md`.
- Keep POSIX shared behavior in shared modules, not duplicated per-host.
- Lockfiles must not duplicate sources. `lockfile.json` must not carry data already authoritative in `flake.lock`. `suggestions.vscode` is the sole exception (Windows PowerShell cannot evaluate Nix). See `lockfile-enforcement.instructions.md`.
- Centralize daemon/service restarts per OS; restart each daemon at most once per activation. macOS: `src/scripts/lib/macos-daemon-refresh.sh`. Windows: `src/platforms/Windows/modules/Set-NucleusService.ps1`. Cross-platform: `src/scripts/lib.sh`.
- Cross-host parity first: same user-visible contract across MacBook, NixOS, Windows — not running bash on Windows. Windows uses PowerShell; POSIX uses bash. See `cross-host-feature-parity.instructions.md`.
- All services use persistent-daemon semantics by default. Classification: `cross-host-feature-parity.instructions.md` (Service firing policy).
- Sort unordered lists alphabetically; preserve semantic/load order where required.
- Service entry lists are manually maintained in declared order (alphabetical by name, with PDF presets grouped quality-descending). No auto-re-sorting.
- Use sentence case for user-facing UI labels. See `documentation.instructions.md`.
- MacBook menu bar icons default to hidden; only Amphetamine and Stats may show. See `app-autostart.instructions.md` § Menu bar icon policy.
- Use `.yml` for YAML files (except required `.sops.yaml`).
- Do not hide meaningful errors (`2>/dev/null`, `|| true`, `-ErrorAction SilentlyContinue`) unless failure is expected, justified, and still checked.
- Output/log format and severity: `output-handling.instructions.md`. Comment annotations: `comment-annotations.instructions.md`.
- Hostnames: `MacBook`, `NixOS`, `Windows`. Host vs platform naming: `cross-host-feature-parity.instructions.md`.
- Prefer preview/beta/canary channels when viable; if stable is required, add a short `# WHY:` comment.

## Directory roots

- Nucleus owns at most **two native roots per host**: one USER, one SYSTEM. Every user gets `~/.nucleus` (Windows: `%USERPROFILE%\.nucleus`) with symlinks (`user` → USER root, `system` → SYSTEM root). User-intended dirs (`clouds`, `dev`, `Downloads`) stay as-is.
- Native roots: macOS `~/Library/Application Support/nucleus` (USER) / `/Library/Application Support/nucleus` (SYSTEM); NixOS `~/.local/share/nucleus` (USER) / `/var/lib/nucleus` (SYSTEM); Windows `%LOCALAPPDATA%\nucleus` (USER) / `%ProgramData%\nucleus` (SYSTEM).
- **Nucleus code references only root paths.** Services write to `<root>/logs`, `<root>/state`, `<root>/config`, `<root>/run`, `<root>/caddy`. Physical conventional locations are reached only via root→conventional symlinks from activation. Never in service runtime code.
- Symlink direction: `~/.nucleus` → roots, roots → conventional targets. Never reversed. `~/.nucleus` is never a data root and never written to by services.
- Exceptions (not nucleus roots): `/usr/local/*`, `/nix`, `%USERPROFILE%\.agents`, `/run/secrets`, `C:\ProgramData\ssh`, scheduled-task registry env vars, `/etc/nucleus/bin`.

## Interaction Boundaries

- When the user says "only plan", "only research", "do not edit files", the agent MUST NOT create/edit files, run implementation commands, or invoke `/implement-plan`. Read/search only. Hard rule.

## No Backwards Compatibility

- No shims, deprecation layers, or migration glue. Rename/restructure/remove in one commit — no aliases, no fallbacks, no compat wrappers.
- Broken downstream consumers are fixed in the same commit.
- If a change needs a compat layer, make it smaller and more local.
- **No in-code migration cleanup.** Never leave migration logic in permanent code. Migrations are one-time: update every reference in the same breaking commit.
- **One-off migrations never persisted.** Run cleanup on every affected host before merging. Do not record one-off steps in the repo.
- **`MANUAL.md` is ongoing operations only.** Recurring post-apply steps that cannot be automated. Not migration runbooks.

## Security and Activation Invariants

- macOS lock hardening stays enabled: `askForPassword = true` and `askForPasswordDelay = 0`.
- Manual host instructions stay as activation-tail output.
- Dev-repo provisioning runs after secrets/key materialization on both POSIX and Windows.
- Windows long-path support stays enabled in DSC (`LongPathsEnabled = 1`).
- Wallpaper state comes from managed decrypted assets, not ad-hoc local files.
- SOPS recipients stay real and shared; rewrap with `sops updatekeys` after recipient changes.
- Privilege-gating (hard-error default for `src/`; escalate for `scripts/`): `nix-and-script-authoring.instructions.md`. Jellyfin admin-token absence is a separate hard-error concern.
- Package installation: `package-installation-scope.instructions.md`.

## Refactoring Guardrails

- Pre-flight: verify target paths and list files to change.
- When adding new fragments, verify wiring (`imports`, `readFile`, dot-sourcing).
- Keep reusable Windows PowerShell in `src/platforms/Windows/modules/`; keep `src/hosts/Windows/apply.ps1` orchestration-focused.
- Before modifying any file with cross-references, search all references first. Do not start edits until the full reference map is known.
- The root `.gitignore` is a hard invariant: never edit it, stage its changes, or remove entries. Escalate to the user. User-scope git ignore files are symlinked into `~/.config/git/ignore` (`git-scope-terminology.instructions.md`). Other `.gitignore` files require explicit user request. Build pollution must be removed immediately, never silenced.
