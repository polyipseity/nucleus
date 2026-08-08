# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide source of truth. Do not add `.github/copilot-instructions.md`.
- `src/` contains the Nix-based declarative configuration: `flake.nix`, `hosts/` (per-machine configs), and `modules/` (shared logic).
  - `src/flake.lock` is the Nix-mandated lockfile location — Nix requires `flake.lock` adjacent to `flake.nix`. The canonical lockfile storage is under `src/lockfiles/` but `flake.lock` cannot be moved there due to this Nix limitation. It is not duplicated; the `src/lockfiles/` directory holds all other lockfiles (`lockfile.json`, etc.) alongside a symlinked copy of `flake.lock` for organizational consistency.
- `src/users/` contains per-user configuration overlays: registry domain JSON (`src/users/<username>/<domain>.json` with `src/users/default/` fallback; schemas co-located as `src/users/default/<domain>.schema.json`), plus per-user homedir app trees (`vscode/`, `agents/`, `direnv/`, …) resolved via `mkUserOverlay` in `users-overlay.nix` (POSIX) and `Resolve-UserConfig*` in `ConfigHelpers.ps1` (Windows). See `user-config-placement.instructions.md` for the `configs/` vs `users/` placement rule. Runtime assembly of domain JSON uses `users-registry.nix` (Nix), `load-user-registry.sh` / `Load-UserRegistry.ps1` (shell/PowerShell).
- `src/modules/configs/` holds machine-wide singleton configs only (system paths, service configs, runtime read by nucleus-owned scripts) — not per-user homedir deployments.
- Use single-file modules only in `src/modules/`. Do not create `src/modules/<name>/` directories. The only allowed exceptions are `src/modules/macos/` (daemon-refresh.nix, finder-sidebar.nix, preference-gc.nix) and `src/modules/env/` (centralized env var introspection module).
- `scripts/` contains user-facing automation helpers with paired `.sh`/`.ps1` entry points: bootstrap, check, cloud-setup, gc, health-check, replica-sync, replica-reset, update, vm-setup, ai-sync, and others.
- `src/scripts/` contains Nix-internal scripts organized into domain subdirectories:
  - `apply.sh` — POSIX apply dispatcher (kept in root)
  - `cleanup-nix-build-artifacts.sh`, `install-prek-hooks.sh` — ungrouped root scripts
  - `services/` — persistent daemon/service scripts (camilladsp-daemon, camilladsp-heartbeat,
    caddy-trust, cloud-drives-setup, gc-weekly, jellyfin-sync, rclone-mount,
    replica-scheduled-sync, service-watchdog)
  - `lib/` — shared library scripts for symlink hardening, cloud drive setup, dev repo
    provisioning, iCloud exclusions, VM setup, app bundle variables, LaunchServices
    handler registration, and the shared lib.sh
  - `secrets/` — secret provisioning helpers
  - `shell/` — shell integration scripts (zsh init, PowerShell init, completion installation)
  - `configs/` — app config/install scripts and merge helpers (INI merge, JSON merge, GPG config, wallpaper provisioning)
  - `packages/` — package-manager installer scripts (init-rustup, install-cargo-binstall-packages,
    install-uv-tools, install-bun-packages, install-pwsh-module)
  - `editors/` — editor-specific scripts (VS Code workspace trust, extension symlink bridge,
    config symlinks, neovim init)
  - `hosts/` — host-specific scripts: `MacBook/` (macOS) and `NixOS/`.
  - `integrations/` — file-manager and desktop-environment integration scripts
    (open-host-manual, file-manager-pdf-opt)
  - `agents/` — AI agent setup scripts (agent-skills, agents-symlink, sync-clawhub-skills)
  - **Naming rule**:
    - Files under `hosts/MacBook/` MUST start with `macos-` followed by a verb-first name: `macos-<verb>-<target>.<ext>`; entry name = filename.
    - Files under `hosts/NixOS/` MUST start with `nixos-` followed by a verb-first name: `nixos-<verb>-<target>.<ext>`; entry name = filename.
    - All other subdirs follow a two-track convention: **verb-first** for action scripts, **entity-first** for service scripts (see `.agents/instructions/scripts-and-permissions.instructions.md` for the full per-directory table).
    - Rule does not apply to runtime-only scripts or wrapped derivations. Library scripts in
      `lib/` that are host-specific MUST still use the host prefix (e.g., `macos-`). Generic
      cross-platform lib scripts may use natural names.
  - **Placement policy for `hosts/`**:
    1. **Host-specific scripts belong in `hosts/<Host>/`.** If a script is macOS-only,
       NixOS-only, or Linux-only, place it under the corresponding `hosts/<Host>/`
       directory with the appropriate prefix (`macos-` or `nixos-`).
    2. **Cross-platform scripts → never in `hosts/`.** If a script is cross-platform
       (no OS-specific commands, no host-specific semantics), it must never go under
       `hosts/<Host>/`. It belongs in a non-host folder (`services/`, `configs/`,
       `packages/`, `editors/`, `lib/`, `secrets/`, `shell/`, `agents/`, `integrations/`, or the root
       of `src/scripts/`).
    - The `hosts/<Host>/` directory exists for host-specific scripts only.
    - Library scripts (`lib/`) are exempt from the host-specific placement rule — they stay
      in `lib/` regardless of platform specificity.
- `tests/` contains automated tests: `tests/modules/`, `tests/integration/`, and `tests/hosts/<host>/` for Nix logic tests, `tests/hosts/Windows/` for Pester DSC validation. All changes require corresponding tests; see `.agents/instructions/testing.instructions.md`.
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

### Pre-flight dependency policy (check scripts)

- Every external tool used by any check in `scripts/check.sh` or `scripts/check.ps1` MUST be declared in the pre-flight block.
- A missing tool causes an immediate hard failure — checks MUST NEVER silently skip steps due to unavailable dependencies.
- The pre-flight block is the single source of truth for all tool requirements.
- To add a new check that requires a new tool: add it to pre-flight first, then provision it on all target hosts (`src/modules/core.nix` for POSIX, `Ensure-Tool` / bootstrap for Windows).

### Dynamic file discovery in check/test scripts

- Check scripts (`scripts/check.sh`, `scripts/check.ps1`) and test scripts (`scripts/test.sh`) MUST auto-discover the files they validate rather than hard-coding file lists.
- Adding a new schema-validation pair, test directory, or file type must NOT require editing the check/test script — it must be automatically picked up via discovery patterns (inline `$schema`, `find` on `tests/`, etc.).
- Exceptions are allowed only for files that lack an inline `$schema` and use built-in schemas (e.g., GitHub workflow files with `--builtin-schema vendor.github-workflows`).

## Build and Validation

### Rust

- `cargo-nextest` is the managed Rust test runner. See
  `src/users/default/nextest/config.toml` (limitations section at top) for known
  limitations.

- Discover commands from the repository itself; never assume a default stack.
- Validate changed files before finishing work:
  - Nix syntax/eval: `nix-instantiate --parse <file.nix>` or `nix flake check` from `src/`
  - PowerShell parse checks: `nix shell nixpkgs#powershell -c pwsh ...`
- PowerShell naming policy: `.agents/instructions/pwsh-lint-policy.instructions.md` (Verb-Noun, collection-singular nouns, semantic manifest in `scripts/pwsh-naming-manifest.json`)
  - WinGet DSC what-if: `winget configure --what-if .\src\hosts\Windows\system.dsc.yml`, `.\src\hosts\Windows\system-packages.dsc.yml`, `.\src\hosts\Windows\user.dsc.yml`, `.\src\hosts\Windows\user-env.dsc.yml`, `.\src\hosts\Windows\user-context.dsc.yml`
- All `nucleus-*` commands are expected to run from any directory: `nucleus-ai-sync`, `nucleus-apply`, `nucleus-audit-store`, `nucleus-bootstrap`, `nucleus-bump-lockfile`, `nucleus-check-pwsh`, `nucleus-check-sh`, `nucleus-cloud-setup`, `nucleus-gc`, `nucleus-health-check`, `nucleus-replica-reset`, `nucleus-replica-sync`, `nucleus-update`, `nucleus-vm`.
- Hard rule: never filter or truncate `nucleus-apply` output (no `grep`, `head`, `tail`, or similar). Run it directly and capture the full combined stdout+stderr. When reviewing output, ignore the direnv environment variable dump (`direnv: export +AR +AR_FOR_BUILD ...`) that sometimes appears at the end — it is irrelevant noise from `.envrc` re-evaluation. If the output ends abruptly (no clear success/failure end marker, partial lines, or incomplete direnv dump) or the exit code is non-zero, do NOT re-run — instead, read the last visible activation step name and diagnose the failure there.
- Known upstream caveat: `builtins.derivation`/`options.json` contextless-source warning is upstream, not a local regression unless concrete local breakage is shown.

## Testing

- Tests are required for feature additions and breaking changes.
- Detailed testing guidance lives in `.agents/instructions/testing.instructions.md`.
- The step-runner framework contract for check/test pipelines lives in `.agents/instructions/step-runner.instructions.md`.

## Core Conventions

- Host block-level filesystem scope (managed vs OS defaults, bootstrap-only steps) lives in `.agents/instructions/host-filesystem-scope.instructions.md`.
- Prefer declarative state (`src/modules/*.nix`, WinGet DSC YAML) over imperative scripts.
- Config deployment follows priority-ordered methods defined in `.agents/instructions/app-config-policy.instructions.md`: writable symlink (default) > read-only > merge > runtime direct read. Any deviation from the default must have a code comment explaining why.
- Git scope terminology is canonical: "global" means machine-wide (`git --system`), "user" means per-user (`git --global`). Never use "global" for `--global`. See `.agents/instructions/git-scope-terminology.instructions.md`.
- Keep POSIX shared behavior in shared modules, not duplicated per-host.
- Centralize all daemon and service restarts per OS and restart each daemon at most once per activation run. macOS daemon refreshes go in `src/modules/macos/daemon-refresh.nix`; Windows SCM operations go in `src/hosts/Windows/modules/Set-NucleusService.ps1`; cross-platform shell helpers go in `src/scripts/lib.sh`.
- Design for cross-host parity first; see `.agents/instructions/cross-host-feature-parity.instructions.md` for the full policy. Parity means the same user-visible contract (CLI flags, behavior, provisioning, docs, tests) across MacBook, NixOS, and Windows — not running bash on Windows. Windows uses native PowerShell (`scripts/*.ps1`, `src/hosts/Windows/modules/*.ps1`); POSIX uses bash (`scripts/*.sh`, `src/scripts/**/*.sh`). Paired entry points (`foo.sh` + `foo.ps1`) or shared declarative data (`*.json` + schema) consumed by both sides are the default pattern.
- All services use persistent-daemon semantics by default (auto-start + auto-restart). See `cross-host-feature-parity.instructions.md` (Service firing policy section) for the default policy and per-service classification.
- Sort unordered lists/blocks alphabetically; preserve semantic/load order where required.
- Service entry lists (currentNucleusAppBundles, currentNucleusWorkflows,
  gsPdfOptPresets, context-pdf-opt.dsc.yml) are manually maintained in their
  declared order — alphabetical by entry name, with the 5 Optimize PDF presets
  grouped as a block sorted quality-descending (default → prepress → printer
  → ebook → screen). No automatic re-sorting; see inline comments in each
  source file for details.
- Use sentence case for all user-facing UI labels (right-click menus, dock/folder/script labels, visible text); see `.agents/instructions/documentation.instructions.md` (UI Label Naming Convention section).
- Use `.yml` for YAML files (except required `.sops.yaml`).
- Do not hide meaningful errors (`2>/dev/null`, unconditional `|| true`, `-ErrorAction SilentlyContinue`) unless failure is expected, explicitly justified, and still checked.
- Comment annotations (suppressions, references, rationale, sentinels) follow the unified grammar and four-category taxonomy in `.agents/instructions/comment-annotations.instructions.md`; Category 1+2 annotations must be machine-parsed, Category 3+4 must not.
- Keep canonical hostnames and display names aligned: `MacBook`, `NixOS`, `Windows`.
- Prefer preview/beta/canary channels when viable; if stable is required, add a short `# WHY:` comment.

## Interaction Boundaries

- When the user says "only plan", "only research", "do not start implement", or "do not edit files", the agent MUST NOT create or edit any files, run any implementation- related commands, or invoke `/implement-plan`. Only read/search operations and text output are permitted. This is a hard rule, not a suggestion.

## No Backwards Compatibility

- This codebase has zero tolerance for backwards-compatibility shims, deprecation layers, or migration glue. When renaming, restructuring, or removing something, do it in one commit — no aliases, no fallbacks, no compat wrappers.
- Broken downstream consumers (own configs, templates, scripts) are fixed in the same commit, not patched later.
- If a change would be painful without a compat layer, the correct response is to make the change smaller and more local, not to add a compat shim.
- **No in-code migration cleanup.** Never leave migration logic in permanent scripts, activation hooks, or modules (for example: detecting an old path and deleting it, dual-read fallbacks, or "rename then remove legacy" blocks). Migrations are one-time: update every reference in the same breaking commit and implement only the new path going forward.
- **One-off migrations are never persisted in the repository.** When a breaking change requires on-disk cleanup on deployed hosts, run that cleanup on every affected host before merging the commit that removes migration glue. Do not record one-off migration steps anywhere in the repo — not in scripts, not in `MANUAL.md`, not in activation-tail output, not in `.agents/instructions/`. After handlers are removed, conflicting on-disk state fails apply; fix it at the console from the error message.
- **`MANUAL.md` is ongoing operations only.** Host `MANUAL.md` files document recurring post-apply steps that cannot be automated (permissions, third-party sign-in, hardware-specific setup). They are not migration runbooks and must never contain one-off or deferred migration checklists.

## Security and Activation Invariants

- macOS lock hardening stays enabled: `askForPassword = true` and `askForPasswordDelay = 0`.
- Manual host instructions must remain activation-tail output (Nix and Windows apply paths).
- Dev-repo provisioning must run after secrets/key materialization on both POSIX and Windows paths.
- Keep Windows long-path support enabled in DSC (`LongPathsEnabled = 1`).
- Wallpaper state must come from managed decrypted assets, not ad-hoc local files.
- Keep SOPS recipients real and shared across encrypted files; rewrap encrypted files with `sops updatekeys` after recipient changes.

See `.agents/instructions/package-installation-scope.instructions.md` for package installation policies.

## Refactoring Guardrails

- Pre-flight: verify target paths and explicitly list files to be changed.
- When adding new fragments (`.json`, `.md`, `.nix`, `.ps1`), verify wiring (`imports`, `readFile`, dot-sourcing).
- Keep reusable Windows PowerShell logic in `src/hosts/Windows/modules/`; keep `src/hosts/Windows/apply.ps1` orchestration-focused.
- Before modifying any file that has cross-references (imports, callers, grep patterns), first run an exhaustive search of all references and report them. Do not start edits until the full reference map is known.
- The root `.gitignore` is a hard invariant: never edit it, stage its changes, or remove entries that look stale — even when a path it ignores no longer exists. Escalate any perceived need to the user instead. User-scope git ignore files (`src/users/*/git/*.gitignore`) are symlinked into `~/.config/git/ignore` (see `.agents/instructions/git-scope-terminology.instructions.md`). Other `.gitignore` files require explicit user request. Untracked build pollution (e.g. `node_modules/` from `bun install`) must be removed immediately, never silenced with gitignore edits.
