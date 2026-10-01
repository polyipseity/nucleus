# Project Guidelines

Inspect the on-disk tree before assuming source files, tests, or commands exist. Keep this file short: file-type and workflow rules go in `.agents/instructions/*.instructions.md`, reusable workflows in `.agents/prompts/*.prompt.md`, skills in `.agents/skills/<skill>/`. There is no `docs/` directory, and `.github/copilot-instructions.md` must never be added.

## Repository shape

- `src/`: `flake.nix` with `flake.lock` adjacent (Nix requirement), `hosts/<Host>/`, `platforms/<Platform>/`, `modules/`, `scripts/`, `users/`.
- `src/hosts/<Host>/` is host-specific deployment: flake system config (`MacBook/`, `NixOS/`), Windows `apply.ps1` + DSC YAML, `<Host>/scripts/`. Hostnames are `MacBook`, `NixOS`, `Windows`; platform keys are `macOS`, `NixOS`, `Windows` (`host-platform-registry.json`).
- `src/platforms/<Platform>/` is logic shared by every host on that OS: Home Manager modules, activation scripts, Windows PowerShell modules.
- `src/modules/` is cross-host shared Nix, single-file modules preferred, `src/modules/env/` is the one directory module. Layout exceptions: `src/modules/configs/` (machine-wide singletons with host-keyed variants) and `src/users/` (per-user overlays). See `user-config-placement.instructions.md` and `app-config-policy.instructions.md`.
- `src/users/` overlays: registry domain JSON (`<username>/<domain>.json` with `default/` fallback, co-located schemas), per-user app trees, runtime assembly (`users-registry.nix`, `load-user-registry.sh`, `Load-UserRegistry.ps1`). Domain deep-merge via `lib.recursiveUpdate`; arrays replaced wholesale.
- `scripts/` is the user-facing `nucleus-*` CLI set, each command paired `.sh`/`.ps1`. `src/scripts/` is Nix-internal tooling in domain subdirectories. Placement: `script-authoring.instructions.md`; command surface: `nucleus-apps.instructions.md`.
- `tests/` mirrors `src/`, uses `tests/fixtures/`, and must not couple to real users. See `testing.instructions.md`.
- Agent customization is file-driven: `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`; `.opencode/commands/` mirrors `.agents/prompts/`. Repository automation lives in `.github/`; formatting config in `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`, `.agents/.markdownlint.jsonc`.

## Build and validation

- Discover commands from the repo, never assume a default stack. Taxonomy: `tooling-and-validation.instructions.md`.
- Every external tool used by `scripts/check.sh` or `scripts/check.ps1` must be declared in the pre-flight block; a missing tool hard-fails.
- Every JSON and YAML data file MUST carry an inline `$schema` pointing at its co-located schema file. JSONC files that already embed one need nothing else.
- `cargo-nextest` is the managed Rust test runner; known limits in `src/users/default/nextest/config.toml`.
- Single registration surface: declare each `nucleus-*` command once in `mkNucleusApps` (`src/flake.nix`). PATH, `nix run`, and `packages` all flow from it, so never hand-register in two places.
- `nucleus-bootstrap` installs Nix and base deps only and never depends on apply. It may invoke apply via `--apply`/`-Apply` once deps exist.
- Never filter or truncate `nucleus-apply` output: capture full stdout+stderr, ignore the direnv dump at the end, and on a non-zero exit read the last activation step instead of re-running.
- Nix is unavailable on Windows: keep Nix changes small and isolated and lean on CI.

## Core conventions

- Prefer declarative state over imperative scripts.
- Config deployment priority: writable symlink (default) > read-only > merge > runtime direct read (`app-config-policy.instructions.md`). Deviations require a code comment.
- Git scope: "global" means machine-wide (`git --system`), "user" means per-user (`git --global`). Never use "global" for `--global`. See `git-scope-terminology.instructions.md`.
- Keep shared POSIX behavior in shared modules instead of duplicating it per host. Parity comes first across MacBook, NixOS, and Windows: Windows is PowerShell, POSIX is bash, never bash on Windows (`cross-host-feature-parity.instructions.md`).
- Centralize daemon and service restarts per OS, and restart each daemon at most once per activation. See `cross-host-feature-parity.instructions.md` for the library per platform.
- Services are persistent daemons by default. See `service-firing-policy.reference.md`.
- Lockfiles must not duplicate sources: `lockfile.json` cannot carry data already authoritative in `flake.lock`. `suggestions.vscode` is the sole exception because Windows PowerShell cannot evaluate Nix. See `lockfile-enforcement.instructions.md`.
- Sort unordered lists alphabetically; preserve semantic or load order where it matters. Service entry lists are maintained by hand in declared order (alphabetical by name, PDF presets grouped quality-descending) and never auto-re-sorted.
- Sentence case for user-facing UI labels (`documentation.instructions.md`). `.yml` for YAML files, except required `.sops.yaml`.
- Prefer preview/beta/canary channels when viable; when stable is required, add a short `# WHY:` comment.
- Do not hide meaningful errors (`2>/dev/null`, `|| true`, `-ErrorAction SilentlyContinue`) unless the failure is expected, justified, and still checked.
- Output format and severity: `output-handling.instructions.md`. Comment annotations: `comment-annotations.instructions.md`. Privilege gating (hard error in `src/`, escalate in `scripts/`): `script-authoring.instructions.md`. Package installation: `package-installation-scope.instructions.md`. Host filesystem scope: `host-filesystem-scope.instructions.md`. Testing: `testing.instructions.md`. Step-runner framework: `step-runner.instructions.md`.
- Shared state flows through the step-runner context object, never ambient scope.

## Directory roots

- At most two native roots per host, one USER and one SYSTEM. Every user gets `~/.nucleus` (Windows `%USERPROFILE%\.nucleus`) with `user` and `system` symlinks into them. User-intended dirs (`clouds`, `dev`, `Downloads`) stay as-is.
- macOS: USER `~/Library/Application Support/nucleus`, SYSTEM `/Library/Application Support/nucleus`. NixOS: USER `~/.local/share/nucleus`, SYSTEM `/var/lib/nucleus`. Windows: USER `%LOCALAPPDATA%\nucleus`, SYSTEM `%ProgramData%\nucleus`.
- Nucleus code references only root paths. Services write to `<root>/logs`, `<root>/state`, `<root>/config`, `<root>/run`, `<root>/caddy`; physical conventional locations are reached only through root→conventional symlinks created by activation, never from service runtime code.
- Symlink direction: `~/.nucleus` → roots, roots → conventional targets. Never reversed. `~/.nucleus` is never a data root and services never write to it.
- Not nucleus roots: `/usr/local/*`, `/nix`, `%USERPROFILE%\.agents`, `/run/secrets`, `C:\ProgramData\ssh`, scheduled-task registry env vars, `/etc/nucleus/bin`.

## Interaction boundaries

When the user says "only plan", "only research", or "do not edit files", the agent MUST NOT create or edit files, run implementation commands, or invoke `/implement-plan`. Read and search only. Hard rule.

## No backwards compatibility

- No shims, deprecation layers, or migration glue. Rename, restructure, or remove in one commit: no aliases, no fallbacks, no compat wrappers. Fix broken downstream consumers in the same commit. If a change needs a compat layer, make it smaller and more local.
- Never leave migration logic in permanent code. Migrations are one-time: update every reference in the same breaking commit, and run cleanup on every affected host before merging. One-off steps never get recorded in the repo.
- `MANUAL.md` is ongoing operations only: recurring post-apply steps that cannot be automated, not migration runbooks.

## Security and activation invariants

- macOS lock hardening stays enabled: `askForPassword = true`, `askForPasswordDelay = 0`. Windows long-path support stays enabled in DSC (`LongPathsEnabled = 1`).
- Manual host instructions stay as activation-tail output. Dev-repo provisioning runs after secrets and key materialization on both POSIX and Windows.
- Wallpaper state comes from managed decrypted assets, never ad-hoc local files.
- SOPS recipients stay real and shared; rewrap with `sops updatekeys` after a recipient changes. A missing Jellyfin admin token is a hard error, not a separate gating case.

## Refactoring guardrails

- Verify target paths and list the files to change before starting. When adding a fragment, verify wiring (`imports`, `readFile`, dot-sourcing).
- Keep reusable Windows PowerShell in `src/platforms/Windows/modules/` and `src/hosts/Windows/apply.ps1` orchestration-focused.
- Before modifying a file with cross-references, map every reference first. Do not start edits until the map is complete.
- The root `.gitignore` is a hard invariant: never edit it, stage its changes, or remove entries. Escalate to the user. User-scope git ignore files are symlinked into `~/.config/git/ignore` (`git-scope-terminology.instructions.md`); other `.gitignore` files need an explicit user request. Remove build pollution immediately, never silence it.
