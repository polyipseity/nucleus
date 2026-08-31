# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide canonical reference. Do not add `.github/copilot-instructions.md`.
- `src/` contains the Nix-based declarative configuration: `flake.nix`, `hosts/` (per-machine configs), `platforms/` (per-platform logic), and `modules/` (cross-host shared logic).
  - `src/flake.lock` must sit adjacent to `flake.nix` (Nix requirement). `src/lockfiles/` stores all other lockfiles (`lockfile.json`, etc.) plus a symlinked copy of `flake.lock`.
- `src/hosts/<Host>/` — host-specific deployment: flake system config (`MacBook/`, `NixOS/`), Windows `apply.ps1` + DSC YAML (`Windows/`), host-only activation scripts (`<Host>/scripts/`).
- `src/platforms/<Platform>/` — platform-specific logic shared across hosts on that OS family: Home Manager modules (`modules/`), activation scripts (`scripts/`), Windows PowerShell modules (`Windows/modules/`). Keys: `macOS`, `NixOS`, `Windows` (canonical capitalization from `host-platform-registry.json`).
- `src/modules/` — cross-host shared Nix modules only (`home.nix`, `core.nix`, `lib/`, …). Use single-file modules; the only allowed subdirectory exception is `src/modules/env/` (centralized env var introspection).
- **Layout exceptions** (do not move under `hosts/` or `platforms/`): `src/modules/configs/` (machine-wide singleton configs with host-keyed variants) and `src/users/` (per-user overlays — registry domain JSON, homedir app trees). See `user-config-placement.instructions.md` and `app-config-policy.instructions.md`.
- `src/users/` contains per-user overlays: registry domain JSON (`src/users/<username>/<domain>.json` with `src/users/default/` fallback; schemas co-located in `src/users/default/`), per-user homedir app trees (`vscode/`, `agents/`, `direnv/`, …), and runtime assembly (`users-registry.nix` / `load-user-registry.sh` / `Load-UserRegistry.ps1`). Domain deep-merge via `lib.recursiveUpdate`; arrays replaced wholesale by design.
- `scripts/` contains user-facing automation helpers with paired `.sh`/`.ps1` entry points: bootstrap, check, cloud-setup, gc, health-check, replica-sync, replica-reset, update, vm-setup, ai-sync, and others.
- `src/scripts/` contains Nix-internal scripts organized into domain subdirectories (`services/`, `lib/`, `configs/`, `agents/`, …). Placement rules: `.agents/instructions/scripts-and-permissions.instructions.md`. Activation blocks use the bundle subprocess pattern: `.agents/instructions/activation-scripts.instructions.md`.
- `tests/` mirrors `src/` layout: `tests/hosts/<Host>/`, `tests/platforms/<Platform>/`, `tests/modules/` (cross-host shared), plus `tests/integration/` and `tests/scripts/`. Rule: `src/<layer>/...` → `tests/<layer>/...`. All changes require corresponding tests; see `.agents/instructions/testing.instructions.md`. Tests must not couple to specific real users under `src/users/<username>/`; use `tests/fixtures/` and `testing.instructions.md`.
- No `docs/` directory exists or may be created. Repository documentation lives in `.agents/instructions/*.instructions.md`, `src/hosts/<Host>/MANUAL.md`, or inline comments.
- Keep this file short and durable. Put file-type and workflow-specific rules in `.agents/instructions/*.instructions.md`, reusable workflows in `.agents/prompts/*.prompt.md`, and skill assets in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or runnable commands exist in a given location.

## Architecture

- Agent customization is file-driven:
  - `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`.
  - `.opencode/commands/` mirrors prompt workflows for OpenCode consumers.
- Repository automation lives in `.github/workflows/ci.yml`, `.github/dependabot.yml`, and `.commitlintrc.mjs`.
- Formatting and newline behavior comes from `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`, and `.agents/.markdownlint.jsonc`.

## Conventions

### Inline `$schema` for JSON/YAML data files

- Every JSON and YAML data file MUST include an inline `$schema` property pointing to its schema file.
- This replaces editor-level schema mappings (e.g., VS Code `json.schemas` / `yaml.schemas` in `.vscode/settings.json`) so validation works in any editor and CI.
- Schema files live alongside their data files (e.g., `src/modules/VMs.schema.json` for `src/modules/VMs.json`).
- Configuration files (JSONC) that already embed `$schema` do not need additional mappings.

### Pre-flight and check discovery

Check/test preflight, tool-availability policy, and scoped-mode conventions: `.agents/instructions/tooling-and-validation.instructions.md`. Every external tool used by `scripts/check.sh` or `scripts/check.ps1` must be declared in the pre-flight block; missing tools hard-fail.

## Build and Validation

### Rust

- `cargo-nextest` is the managed Rust test runner. See
  `src/users/default/nextest/config.toml` (limitations section at top) for known
  limitations.

- Discover commands from the repository itself; never assume a default stack. Check-step taxonomy: `.agents/instructions/tooling-and-validation.instructions.md`.
- The nucleus command surface (flake apps, subcommand folding, internal-invocation policy, Windows parity, completion generators) is canonical in `.agents/instructions/nucleus-apps.instructions.md`. Do not add new single-purpose `nucleus-*` PATH commands.
- **Single registration surface:** every nucleus command is declared once in `mkNucleusApps` (`src/flake.nix`); PATH (`home.packages`), `nix run` (`apps`, derived via `mkNucleusAppsAsFlakeApps`), and `packages` all flow from it. Never hand-register a command in two places.
- **Bootstrap independence:** `nucleus-bootstrap` installs Nix + base deps only and must never depend on apply; it may optionally invoke apply via `--apply`/`-Apply` after deps exist, but apply is never a bootstrap dependency.
- Hard rule: never filter or truncate `nucleus-apply` output (no `grep`, `head`, `tail`, or similar). Capture the full combined stdout+stderr. Ignore the direnv dump (`direnv: export +AR +AR_FOR_BUILD ...`) that sometimes appears at the end — irrelevant noise from `.envrc` re-evaluation. If the output ends abruptly (no clear end marker, partial lines, incomplete direnv dump) or the exit code is non-zero, do NOT re-run — read the last visible activation step name and diagnose there.
- Known upstream caveat: `builtins.derivation`/`options.json` contextless-source warning is upstream for `options.json` and `activation-script` derivations; nucleus-fixed for all plist-based `NUCLEUS_REPO_ROOT` derivations via context-preserving string interpolation (not `toString`).

## Testing

- Tests are required for feature additions and breaking changes.
- Detailed testing guidance lives in `.agents/instructions/testing.instructions.md`.
- The step-runner framework contract for check/test pipelines lives in `.agents/instructions/step-runner.instructions.md`.
- Shared state in check/test scripts must flow through the step-runner context object, never ambient scope; see `.agents/instructions/no-ambient-passing.instructions.md`.

## Core Conventions

- Host block-level filesystem scope: `.agents/instructions/host-filesystem-scope.instructions.md`.
- Prefer declarative state (`src/modules/*.nix`, WinGet DSC YAML) over imperative scripts.
- Config deployment follows priority-ordered methods defined in `.agents/instructions/app-config-policy.instructions.md`: writable symlink (default) > read-only > merge > runtime direct read. Any deviation from the default must have a code comment explaining why.
- Git scope terminology: "global" means machine-wide (`git --system`), "user" means per-user (`git --global`). Never use "global" for `--global`. See `.agents/instructions/git-scope-terminology.instructions.md`.
- Keep POSIX shared behavior in shared modules, not duplicated per-host.
- Lockfiles must not duplicate each other sources: `lockfile.json` must not carry version/pin data already authoritative in another lockfile (`flake.lock` owns nixpkgs and homebrew tap revisions). Nix modules listing package names are not lockfiles. `suggestions.vscode` is the sole intentional exception (Windows PowerShell provisioning cannot evaluate Nix to resolve the version) — see `.agents/instructions/lockfile-enforcement.instructions.md`.
- Centralize all daemon/service restarts per OS; restart each daemon at most once per activation run. macOS: `src/scripts/lib/macos-daemon-refresh.sh`. Windows: `src/platforms/Windows/modules/Set-NucleusService.ps1`. Cross-platform: `src/scripts/lib.sh`.
- Cross-host parity first (`.agents/instructions/cross-host-feature-parity.instructions.md`): same user-visible contract (CLI flags, behavior, provisioning, docs, tests) across MacBook, NixOS, and Windows — not running bash on Windows. Windows uses PowerShell (`scripts/*.ps1`, `src/platforms/Windows/modules/*.ps1`); POSIX uses bash (`scripts/*.sh`, `src/scripts/**/*.sh`). Paired entry points or shared declarative data (`*.json` + schema) are the default pattern.
- All services use persistent-daemon semantics by default (auto-start + auto-restart). Per-service classification: `cross-host-feature-parity.instructions.md` (Service firing policy section).
- Sort unordered lists/blocks alphabetically; preserve semantic/load order where required.
- Service entry lists (currentNucleusAppBundles, currentNucleusWorkflows,
  optimizePdfPresets, context-optimize-pdf.dsc.yml) are manually maintained in their
  declared order — alphabetical by entry name, with the 5 Optimize PDF presets
  grouped as a block sorted quality-descending (default → prepress → printer
  → ebook → screen). No automatic re-sorting; see inline comments in each
  source file for details.
- Use sentence case for all user-facing UI labels (right-click menus, dock/folder/script labels, visible text); see `.agents/instructions/documentation.instructions.md` (UI Label Naming Convention section).
- MacBook menu bar icons default to hidden; only Amphetamine and Stats may show. Policy, per-app hide mechanisms, and system-item keys: `.agents/instructions/menu-bar-policy.instructions.md`.
- Use `.yml` for YAML files (except required `.sops.yaml`).
- Do not hide meaningful errors (`2>/dev/null`, unconditional `|| true`, `-ErrorAction SilentlyContinue`) unless failure is expected, explicitly justified, and still checked.
- All command output and log files follow the canonical logging standard in `.agents/instructions/logging.instructions.md` (F1-F5 formats, console colors, log storage/rotation).
- Error vs warning vs info severity: `.agents/instructions/error-handling.instructions.md` (hard-error default; warning requires `# check-suppress` justification). Level taxonomy: `logging.instructions.md`.
- Comment annotations follow `.agents/instructions/comment-annotations.instructions.md` (suppressions, references, rationale, sentinels); Category 1+2 machine-parsed, Category 3+4 not.
- Hostnames: `MacBook`, `NixOS`, `Windows`. Host vs platform naming: `.agents/instructions/cross-host-feature-parity.instructions.md` (Host vs platform naming section).
- Prefer preview/beta/canary channels when viable; if stable is required, add a short `# WHY:` comment.

## Directory roots

- Nucleus owns at most **two native roots per host**: one USER, one SYSTEM, both native per-OS. Every user gets a `~/.nucleus` convenience hub (Windows: `%USERPROFILE%\.nucleus`) with two symlinks (`user` → USER root, `system` → SYSTEM root). User-intended dirs (`clouds`, `dev`, `virtual machines`, `Pictures/wallpapers`, `Downloads`) stay as-is.
- Native roots: macOS `~/Library/Application Support/nucleus` (USER) / `/Library/Application Support/nucleus` (SYSTEM); NixOS `~/.local/share/nucleus` (USER) / `/var/lib/nucleus` (SYSTEM); Windows `%LOCALAPPDATA%\nucleus` (USER) / `%ProgramData%\nucleus` (SYSTEM).
- **Hard rule: nucleus code references only root paths.** Services/scripts write to `<root>/logs`, `<root>/state`, `<root>/config`, `<root>/run`, `<root>/caddy`. Physical conventional locations (`/var/log/nucleus`, `~/Library/Logs/nucleus`, `/run/nucleus`, `~/.local/state/nucleus`, etc.) are reached only via root→conventional symlinks from activation (and systemd `StateDirectory`/`LogsDirectory`/`RuntimeDirectory`). Never appear in service runtime code.
- Symlink direction is fixed: `~/.nucleus` → roots, and roots → conventional targets. Never reversed. `~/.nucleus` is never a data root and is never written to by services.
- Accepted exceptions (not nucleus roots, left unchanged): `/usr/local/*` (impure Homebrew/fuse-t/battery), `/nix` (OS `synthetic.conf`), `%USERPROFILE%\.agents` (standard agent-tool location), `/run/secrets` (sops-nix default), `C:\ProgramData\ssh` (OS-owned), scheduled-task registry/HKLM/HKCU env vars, `/etc/nucleus/bin` (nvim two-mechanism path).

## Interaction Boundaries

- When the user says "only plan", "only research", "do not start implement", or "do not edit files", the agent MUST NOT create/edit files, run implementation-related commands, or invoke `/implement-plan`. Read/search operations and text output only. Hard rule.

## No Backwards Compatibility

- No backwards-compatibility shims, deprecation layers, or migration glue. When renaming, restructuring, or removing something, do it in one commit — no aliases, no fallbacks, no compat wrappers.
- Broken downstream consumers (own configs, templates, scripts) are fixed in the same commit, not patched later.
- If a change needs a compat layer to be safe, make the change smaller and more local instead.
- **No in-code migration cleanup.** Never leave migration logic in permanent scripts, activation hooks, or modules (detecting an old path and deleting it, dual-read fallbacks, "rename then remove legacy" blocks). Migrations are one-time: update every reference in the same breaking commit; only the new path going forward.
- **One-off migrations are never persisted.** When a breaking change requires on-disk cleanup, run it on every affected host before merging the commit that removes migration glue. Do not record one-off steps anywhere in the repo. After handlers are removed, conflicting on-disk state fails apply; fix at the console from the error message.
- **`MANUAL.md` is ongoing operations only.** Host `MANUAL.md` files document recurring post-apply steps that cannot be automated (permissions, third-party sign-in, hardware-specific setup). Not migration runbooks — never contain one-off or deferred migration checklists.

## Security and Activation Invariants

- macOS lock hardening stays enabled: `askForPassword = true` and `askForPasswordDelay = 0`.
- Manual host instructions stay as activation-tail output (Nix and Windows apply paths).
- Dev-repo provisioning runs after secrets/key materialization on both POSIX and Windows.
- Windows long-path support stays enabled in DSC (`LongPathsEnabled = 1`).
- Wallpaper state comes from managed decrypted assets, not ad-hoc local files.
- SOPS recipients stay real and shared across encrypted files; rewrap with `sops updatekeys` after recipient changes.
- Privilege-gating (hard-error default for `src/`; escalate for user-facing `scripts/`): `.agents/instructions/scripts-and-permissions.instructions.md`. Jellyfin admin-token absence is a separate hard-error concern.

Package installation policies: `.agents/instructions/package-installation-scope.instructions.md`.

## Refactoring Guardrails

- Pre-flight: verify target paths and explicitly list files to be changed.
- When adding new fragments (`.json`, `.md`, `.nix`, `.ps1`), verify wiring (`imports`, `readFile`, dot-sourcing).
- Keep reusable Windows PowerShell logic in `src/platforms/Windows/modules/`; keep `src/hosts/Windows/apply.ps1` orchestration-focused.
- Before modifying any file with cross-references (imports, callers, grep patterns), search all references first and report them. Do not start edits until the full reference map is known.
- The root `.gitignore` is a hard invariant: never edit it, stage its changes, or remove entries that look stale — even when a path it ignores no longer exists. Escalate to the user instead. User-scope git ignore files (`src/users/*/git/*.gitignore`) are symlinked into `~/.config/git/ignore` (`.agents/instructions/git-scope-terminology.instructions.md`). Other `.gitignore` files require explicit user request. Build pollution (e.g. `node_modules/` from `bun install`) must be removed immediately, never silenced with gitignore edits.
