# Project Guidelines

## Repository Shape

- Root `AGENTS.md` is the workspace-wide source of truth. Do not add
  `.github/copilot-instructions.md`.
- `src/` contains the Nix-based declarative configuration: `flake.nix`,
  `hosts/` (per-machine configs), and `modules/` (shared logic).
- Prefer single-file modules in `src/modules/*.nix` unless a module truly needs
  nested sub-components.
- `scripts/` contains bootstrap automation: `bootstrap.sh` (Unix) and
  `bootstrap.ps1` (Windows).
- `tests/` is still a placeholder; test infrastructure has not been added yet.
- Keep this file short and durable. Put file-type and workflow-specific rules
  in `.agents/instructions/*.instructions.md`, reusable workflows in
  `.agents/prompts/*.prompt.md`, and skill assets in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or runnable
  commands exist in a given location.

## Architecture

- Agent customization is file-driven:
  - `opencode.json` registers `.agents/instructions/**/*.md` and
    `.agents/skills/`
  - `.opencode/commands/` mirrors prompt workflows for OpenCode consumers
  - `.vscode/settings.json` defines terminal auto-approve patterns and editor
    behavior
- Repository automation currently lives in:
  - `.github/workflows/ci.yml` for CI scaffolding
  - `.github/dependabot.yml` for dependency-update scope
  - `.commitlintrc.mjs` for commit message policy
- Formatting and newline behavior come from `.editorconfig`, `.gitattributes`,
  `.markdownlint.jsonc`, and `.agents/.markdownlint.jsonc`.

## Build and Test

- Verify the relevant manifests, scripts, workflow files, and local configs
  exist before you run or document toolchain commands.
- Detect install, build, test, lint, format, type-check, and release commands
  from actual repository files instead of assuming a default stack.
- When a language, framework, task runner, or test system is clearly present,
  add or refine focused instruction files for it rather than stuffing detailed
  rules into `AGENTS.md`.
- Keep CI, editor automation, prompt examples, and instruction files aligned
  with the commands and configs that are actually present in the repository.

## Conventions

- Distinguish between what is present today and what is only part of the
  intended template contract. Do not describe absent files as if they already
  exist.
- Before writing stack-specific guidance, inspect concrete evidence such as
  manifests, lockfiles, source tree layout, scripts, CI workflows, editor
  settings, and dedicated config files.
- When you detect a real stack, add instructions for it carefully and
  thoroughly in a narrow, well-named instruction file whose `description` and
  `applyTo` target the relevant files.
- Prefer linking to canonical config files instead of copying large policy
  blocks into multiple customization files.
- Keep customization files narrowly scoped: repo-wide defaults in `AGENTS.md`,
  detailed file-specific guidance in `.agents/instructions/`.
- Preserve mirrored prompt content between `.agents/prompts/` and
  `.opencode/commands/` when both copies exist.
- Respect the repository newline policy: Markdown and shell scripts use LF;
  PowerShell and batch scripts use CRLF.
- **YAML extension policy**: use `.yml` for repository YAML files. Do not add
  long-extension YAML filenames. Exception: `.sops.yaml` is required by SOPS
  config discovery and must keep that exact name.
- **Windows module path**: keep reusable PowerShell functions under
  `src/modules/windows/*.ps1` using lowercase filenames; keep
  `src/hosts/windows/apply.ps1` as a thin trigger/orchestrator.
- **Declarative enforcement**: if a WinGet DSC resource can represent desired
  Windows state, prefer adding it to `system.dsc.yml` or `user.dsc.yml` rather
  than introducing new imperative commands in `bootstrap.ps1` or `apply.ps1`.
- **Declarative first**: imperative code in `src/scripts/apply.sh` and
  `src/hosts/windows/apply.ps1` is treated as a bug. If desired state can be
  represented in Nix modules or WinGet DSC resources, move it there.
- **JIT secrets**: do not materialize secrets globally in orchestration
  wrappers. Materialize secrets only in the module/resource that requires them
  (for example Home Manager activation hooks or targeted Windows module calls).
- **Sorting**: always sort items in any list (package lists, import lists,
  shell alias lists, shell completions, environment variable blocks) and any
  configuration block that lacks a natural semantic order. Alphabetical
  ascending order is the default. Do not sort items whose order is load-order
  or semantically significant (e.g. `boot.initrd.availableKernelModules`,
  module import lists where one module must precede another).

## Refactoring Guardrails

- **Pre-flight check rule**: before proposing or executing edits, verify target
  paths on disk and list all files that will be changed.
- **Cross-platform symmetry rule**: when adding a capability that exists on
  both Unix and Windows (for example secrets, fonts, or wallpapers), add or
  update both implementations in the same change:
  - Unix side under `src/modules/*.nix`
  - Windows side under `src/modules/windows/*.ps1`
- **Windows module enforcement**: all reusable PowerShell functions must live
  under `src/modules/windows/*.ps1` with lowercase filenames; keep
  `src/hosts/windows/apply.ps1` orchestration-only.

## Key References

- `AGENTS.md` — workspace-wide defaults
- `.agents/instructions/*.instructions.md` — focused authoring rules by file type
- `.agents/prompts/commit-staged.prompt.md` and
  `.opencode/commands/commit-staged.prompt.md` — mirrored commit workflow prompt
- `opencode.json` — instruction and skill discovery
- `.vscode/settings.json` — terminal auto-approve and editor behavior
- `.github/workflows/ci.yml`, `.github/dependabot.yml`, `.commitlintrc.mjs` —
  automation and policy
- `.editorconfig`, `.gitattributes`, `.markdownlint.jsonc`,
  `.agents/.markdownlint.jsonc` — formatting and line-ending rules
- `src/flake.nix` — Nix flake entrypoint (hosts + home-manager outputs)
- `src/hosts/` — per-machine configurations (macbook, nixos, windows)
- `src/modules/` — shared Nix modules (`*.nix`) and Windows helper modules
  (`windows/*.ps1`)
- `scripts/bootstrap.sh`, `scripts/bootstrap.ps1` — one-command setup wrappers
