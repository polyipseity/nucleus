# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide source of truth. Do not add `.github/copilot-instructions.md`.
- `src/` contains the Nix-based declarative configuration: `flake.nix`, `hosts/` (per-machine configs), and `modules/` (shared logic).
  - `src/flake.lock` is the Nix-mandated lockfile location — Nix requires `flake.lock` adjacent to `flake.nix`. The canonical lockfile storage is under `src/lockfiles/` but `flake.lock` cannot be moved there due to this Nix limitation. It is not duplicated; the `src/lockfiles/` directory holds all other lockfiles (`lockfile.json`, etc.) alongside a symlinked copy of `flake.lock` for organizational consistency.
- Use single-file modules only in `src/modules/`. Do not create `src/modules/<name>/` directories. The only allowed exceptions are `src/modules/macos/` (daemon-refresh.nix, finder-sidebar.nix, preference-gc.nix) and `src/modules/env/` (centralized env var introspection module).
- `scripts/` contains automation helpers with paired `.sh`/`.ps1` entry points: bootstrap, check, cloud-setup, gc, health-check, replica-sync, replica-reset, update, vm-setup, ai-sync, and others.
- `tests/` contains automated tests: `tests/modules/`, `tests/integration/`, and `tests/hosts/<host>/` for Nix logic tests, `tests/hosts/Windows/` for Pester DSC validation. All changes require corresponding tests; see `.agents/instructions/testing.instructions.md`.
- Keep this file short and durable. Put file-type and workflow-specific rules in `.agents/instructions/*.instructions.md`, reusable workflows in `.agents/prompts/*.prompt.md`, and skill assets in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or runnable commands exist in a given location.

## Architecture

- Agent customization is file-driven:
  - `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`.
  - `.opencode/commands/` mirrors prompt workflows for OpenCode consumers.
- Repository automation lives in `.github/workflows/ci.yml`, `.github/dependabot.yml`, and `.commitlintrc.mjs`.
- Formatting and newline behavior comes from `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`, and `.agents/.markdownlint.jsonc`.

## Build and Validation

- Discover commands from the repository itself; never assume a default stack.
- Validate changed files before finishing work:
  - Nix syntax/eval: `nix-instantiate --parse <file.nix>` or `nix flake check` from `src/`
  - PowerShell parse checks: `nix shell nixpkgs#powershell -c pwsh ...`
  - WinGet DSC what-if: `winget configure --what-if .\src\hosts\Windows\system.dsc.yml`, `.\src\hosts\Windows\system-packages.dsc.yml`, `.\src\hosts\Windows\user.dsc.yml`, `.\src\hosts\Windows\user-env.dsc.yml`, `.\src\hosts\Windows\user-context.dsc.yml`
- All `nucleus-*` commands are expected to run from any directory: `nucleus-ai-sync`, `nucleus-apply`, `nucleus-bootstrap`, `nucleus-bump-lockfile`, `nucleus-check-pwsh`, `nucleus-check-sh`, `nucleus-cloud-setup`, `nucleus-gc`, `nucleus-health-check`, `nucleus-replica-reset`, `nucleus-replica-sync`, `nucleus-update`, `nucleus-vm-setup`.
- Hard rule: never filter or truncate `nucleus-apply` output (no `grep`, `head`, `tail`, or similar). Run it directly and capture the full combined stdout+stderr. When reviewing output, ignore the direnv environment variable dump (`direnv: export +AR +AR_FOR_BUILD ...`) that sometimes appears at the end — it is irrelevant noise from `.envrc` re-evaluation. If the output ends abruptly (no clear success/failure end marker, partial lines, or incomplete direnv dump) or the exit code is non-zero, do NOT re-run — instead, read the last visible activation step name and diagnose the failure there.
- Known upstream caveat: `builtins.derivation`/`options.json` contextless-source warning is upstream, not a local regression unless concrete local breakage is shown.

## Testing

- Tests are required for feature additions and breaking changes.
- Detailed testing guidance lives in `.agents/instructions/testing.instructions.md`.

## Core Conventions

- Prefer declarative state (`src/modules/*.nix`, WinGet DSC YAML) over imperative scripts.
- Config deployment follows priority-ordered methods defined in `.agents/instructions/app-config-policy.instructions.md`: writable symlink (default) > read-only > merge > runtime direct read. Any deviation from the default must have a code comment explaining why.
- Keep POSIX shared behavior in shared modules, not duplicated per-host.
- Centralize all daemon and service restarts per OS and restart each daemon at most once per activation run. macOS daemon refreshes go in `src/modules/macos/daemon-refresh.nix`; Windows SCM operations go in `src/hosts/Windows/modules/Set-NucleusService.ps1`; cross-platform shell helpers go in `src/scripts/lib.sh`.
- Design for cross-host parity first; see `.agents/instructions/cross-host-feature-parity.instructions.md` for the full policy.
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
- Keep canonical hostnames and display names aligned: `MacBook`, `NixOS`, `Windows`.
- Prefer preview/beta/canary channels when viable; if stable is required, add a short `# WHY`.

## Interaction Boundaries

- When the user says "only plan", "only research", "do not start implement", or "do not edit files", the agent MUST NOT create or edit any files, run any implementation- related commands, or invoke `/implement-plan`. Only read/search operations and text output are permitted. This is a hard rule, not a suggestion.

## No Backwards Compatibility

- This codebase has zero tolerance for backwards-compatibility shims, deprecation layers, or migration glue. When renaming, restructuring, or removing something, do it in one commit — no aliases, no fallbacks, no compat wrappers.
- Broken downstream consumers (own configs, templates, scripts) are fixed in the same commit, not patched later.
- If a change would be painful without a compat layer, the correct response is to make the change smaller and more local, not to add a compat shim.

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
