# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide source of truth. Do not add
  `.github/copilot-instructions.md`.
- `src/` contains the Nix-based declarative configuration: `flake.nix`,
  `hosts/` (per-machine configs), and `modules/` (shared logic).
- Prefer single-file modules in `src/modules/*.nix` unless a module truly needs
  nested sub-components.
- `scripts/` contains automation helpers with paired `.sh`/`.ps1` entry points:
  bootstrap, check, cloud-setup, gc, health-check, replica-sync, replica-reset,
  update, vm-setup, ai-sync, and others.
- `tests/` contains automated tests: `tests/src/` for Nix logic tests,
  `tests/src/hosts/Windows/` for Pester DSC validation. All changes require corresponding
  tests; see `.agents/instructions/testing.instructions.md`.
- Keep this file short and durable. Put file-type and workflow-specific rules
  in `.agents/instructions/*.instructions.md`, reusable workflows in
  `.agents/prompts/*.prompt.md`, and skill assets in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or runnable
  commands exist in a given location.

## Architecture

- Agent customization is file-driven:
  - `opencode.jsonc` registers `.agents/instructions/**/*.md` and `.agents/skills/`.
  - `.opencode/commands/` mirrors prompt workflows for OpenCode consumers.
  - `.vscode/settings.json` defines terminal auto-approve patterns and editor behavior.
- Repository automation lives in `.github/workflows/ci.yml`,
  `.github/dependabot.yml`, and `.commitlintrc.mjs`.
- Formatting and newline behavior comes from `.editorconfig`, `.gitattributes`,
  `.markdownlint.jsonc`, and `.agents/.markdownlint.jsonc`.

## Build and Validation

- Discover commands from the repository itself; never assume a default stack.
- Validate changed files before finishing work:
  - Nix syntax/eval: `nix-instantiate --parse <file.nix>` or `nix flake check` from `src/`
  - PowerShell parse checks: `nix shell nixpkgs#powershell -c pwsh ...`
  - WinGet DSC what-if: `winget configure --what-if .\src\hosts\Windows\system.dsc.yml`
    and `winget configure --what-if .\src\hosts\Windows\user.dsc.yml`
- All `nucleus-*` commands are expected to run from any directory:
  `nucleus-ai-sync`, `nucleus-apply`, `nucleus-bootstrap`, `nucleus-check-pwsh`, `nucleus-check-sh`,
  `nucleus-cloud-setup`, `nucleus-gc`, `nucleus-health-check`, `nucleus-replica-reset`,
  `nucleus-replica-sync`, `nucleus-update`, `nucleus-vm-setup`.
- Known upstream caveat: `builtins.derivation`/`options.json` contextless-source warning is upstream,
  not a local regression unless concrete local breakage is shown.
- Treat Dependabot `package-ecosystem: "nix"` as valid even when `check-dependabot` lags schema support.

## Testing

- Tests are required for feature additions and breaking changes.
- Nix tests: `tests/src/*.nix` plus `nix flake check`.
- Windows tests: `tests/src/hosts/Windows/**/*.Tests.ps1` (run locally on Windows).
- Follow TDD flow: write failing test → implement → pass → commit atomically.
- Detailed testing guidance lives in `.agents/instructions/testing.instructions.md`.

## Core Conventions

- Prefer declarative state (`src/modules/*.nix`, WinGet DSC YAML) over imperative scripts.
- Keep POSIX shared behavior in shared modules, not duplicated per-host.
- Design for cross-host parity first; see
  `.agents/instructions/cross-host-feature-parity.instructions.md` for the full policy.
- Sort unordered lists/blocks alphabetically; preserve semantic/load order where required.
- Use `.yml` for YAML files (except required `.sops.yaml`).
- Script files (`.sh`, `.ps1`, `.bat`) must be executable in Git (`100755`);
  non-script files remain `100644`.
- Do not hide meaningful errors (`2>/dev/null`, unconditional `|| true`,
  `-ErrorAction SilentlyContinue`) unless failure is expected, explicitly justified,
  and still checked.
- Keep canonical hostnames and display names aligned: `MacBook`, `NixOS`, `Windows`.
- Use positive option names (see `.agents/instructions/positive-options.instructions.md`).
- Prefer preview/beta/canary channels when viable; if stable is required, add a short `# WHY`.

## No Backwards Compatibility

- This codebase has zero tolerance for backwards-compatibility shims, deprecation
  layers, or migration glue. When renaming, restructuring, or removing something,
  do it in one commit — no aliases, no fallbacks, no compat wrappers.
- Broken downstream consumers (own configs, templates, scripts) are fixed in the
  same commit, not patched later.
- If a change would be painful without a compat layer, the correct response is to
  make the change smaller and more local, not to add a compat shim.

## Security and Activation Invariants

- macOS lock hardening stays enabled: `askForPassword = true` and `askForPasswordDelay = 0`.
- Manual host instructions must remain activation-tail output (Nix and Windows apply paths).
- Dev-repo provisioning must run after secrets/key materialization on both POSIX and Windows paths.
- Keep Windows long-path support enabled in DSC (`LongPathsEnabled = 1`).
- Wallpaper state must come from managed decrypted assets, not ad-hoc local files.
- Keep SOPS recipients real and shared across encrypted files; rewrap encrypted files with
  `sops updatekeys` after recipient changes.

## Package and Editor Policies

- macOS package selection:
  - CLI tools: prefer `nixpkgs`.
  - GUI apps and hardware/deep-integration tools: use Homebrew where required.
- Keep VS Code backend-selectable by OS, with shared settings source and
  Darwin extension-bridge behavior intact.

## Refactoring Guardrails

- Pre-flight: verify target paths and explicitly list files to be changed.
- When adding new fragments (`.json`, `.md`, `.nix`, `.ps1`), verify wiring (`imports`, `readFile`, dot-sourcing).
- Keep reusable Windows PowerShell logic in `src/hosts/Windows/modules/`; keep
  `src/hosts/Windows/apply.ps1` orchestration-focused.
