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
- `tests/` contains automated tests: `tests/nix/` for Nix logic tests,
  `tests/windows/` for Pester DSC validation. All changes require corresponding
  tests; see `.agents/instructions/testing.instructions.md`.
- Keep this file short and durable. Put file-type and workflow-specific rules
  in `.agents/instructions/*.instructions.md`, reusable workflows in
  `.agents/prompts/*.prompt.md`, and skill assets in `.agents/skills/<skill>/`.
- Inspect the on-disk tree before assuming source files, tests, or runnable
  commands exist in a given location.

## Architecture

- Agent customization is file-driven:
  - `opencode.jsonc` registers `.agents/instructions/**/*.md` and
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
- Always validate syntax for changed files before concluding a change. Use
  repository-supported checks such as `nix-instantiate --parse <file.nix>`
  (or `nix flake check` from `src/` for broader Nix validation),
  `nix shell nixpkgs#powershell -c pwsh ...` for PowerShell parser checks, and
  `winget configure --what-if .\src\hosts\windows\system.dsc.yml` plus
  `winget configure --what-if .\src\hosts\windows\user.dsc.yml` for WinGet
  DSC changes.
- For Nix profile operations, prefer `nix profile add` over the deprecated
  `nix profile install` alias, and use presence checks (`nix profile list`)
  in bootstrap scripts to keep reruns idempotent and warning-free.
- When piping `nix profile list` to `grep -q` (or similar early-exit filters),
  redirect stderr to `/dev/null` (`2>/dev/null`) to suppress the SIGPIPE
  "Broken pipe" warning that occurs when `grep` closes the stream early.
- When a language, framework, task runner, or test system is clearly present,
  add or refine focused instruction files for it rather than stuffing detailed
  rules into `AGENTS.md`.
- Keep CI, editor automation, prompt examples, and instruction files aligned
  with the commands and configs that are actually present in the repository.
- Treat `package-ecosystem: "nix"` in `.github/dependabot.yml` as valid even
  when `check-dependabot` reports a schema error; that hook can lag current
  Dependabot ecosystem support.

## Testing Strategy

**nucleus** uses test-driven development (TDD) to catch regressions across
POSIX (macOS/NixOS) and Windows hosts. Tests are mandatory for all feature
additions and breaking changes.

### Nix Testing (macOS/NixOS)

- **Evaluation checks** (`nix flake check`): Ensures all configurations parse
  and module imports are acyclic. Runs on every commit in CI and catches syntax
  errors before they reach live machines.
- **Unit tests** (`tests/nix/*.nix`): Pure logic tests using `nix-instantiate
  --eval` to verify package categorization, backend selection, and module
  defaults. Add tests for any Nix functions with conditional logic or data
  transformations.

### Windows Testing (Pester)

- **DSC validation** (`tests/windows/*.Tests.ps1`): Pester tests verify that
  WinGet packages are installed, registry settings are correct, and security
  invariants are enforced. Run locally on Windows before commit; not run in CI
  (CI uses Linux runners).

### Test Workflow

1. **Write the test first** — describe what correct behavior looks like
2. **Watch it fail** — confirm the test catches the missing feature
3. **Implement the feature** — make the test pass
4. **Commit atomically** — test + implementation in one commit

See `.agents/instructions/testing.instructions.md` for detailed guidance,
quick-start commands, and troubleshooting.

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
- **Executable bit policy**: every `.sh`, `.ps1`, and `.bat` file anywhere in
  the repository must be tracked in Git with mode `100755`. This includes
  `src/hosts/windows/apply.ps1`, all `src/hosts/windows/modules/*.ps1`, and
  `src/scripts/apply.sh`. Set the bit with
  `git update-index --chmod=+x <path>` when adding or renaming any script.
  Non-script files (`.env`, `.yml`, `.json`, `.nix`, `.md`, `.jsonc`) must
  remain `100644`.
- **YAML extension policy**: use `.yml` for repository YAML files. Do not add
  long-extension YAML filenames. Exception: `.sops.yaml` is required by SOPS
  config discovery and must keep that exact name.
- **PowerShell filename policy**: when adding or renaming standalone PowerShell
  entry points, use PascalCase `Verb-Noun` filenames with approved verbs.
  Files in `scripts/` are the exception: they keep the paired shell basename so
  the `.sh` and `.ps1` entry points stay aligned; `check-pwsh.ps1` is the
  intentional runtime-specific exception to `check-sh.sh`.
- **Windows module path**: keep reusable PowerShell functions under
  `src/hosts/windows/modules/*.ps1` with filenames that match the exported
  function name; keep `src/hosts/windows/apply.ps1` as a thin
  trigger/orchestrator.
- **Windows function isolation**: keep one reusable PowerShell function per
  file under `src/hosts/windows/modules/`; orchestrators (for example
  `src/hosts/windows/apply.ps1`) should dot-source only the modules needed for
  the current run.
- **Static config externalization**: keep shared editor settings in standalone
  config files (for example `src/modules/configs/vscode-settings.json`) and
  load them from Nix with `builtins.fromJSON (builtins.readFile ...)` so JSON
  can be linted/validated independently.
- **Manual activation docs**: keep one-time manual instructions in host Markdown
  files (for example `src/hosts/macbook/MANUAL.md`,
  `src/hosts/nixos/MANUAL.md`, and `src/hosts/windows/MANUAL.md`) and have
  activation hooks print those files at the end of every apply (Nix:
  `displayHostManualInstructions`; Windows: `apply.ps1` final step), rather
  than embedding long instruction strings directly in code.
- **Shell module granularity**: keep shell alias/environment attrsets in
  dedicated fragments (for example `src/modules/shell/aliases.nix` and
  `src/modules/shell/env.nix`) with strict alphabetical ordering of keys.
- **NixOS hardware granularity**: when hardware settings grow, split
  `src/hosts/nixos/hardware.nix` into `src/hosts/nixos/hardware/` fragments
  (`cpu.nix`, `gpu.nix`, `disks.nix`) and import them through the host entrypoint.
- **SOPS binary policy docs**: do not add documentation rules that require
  marking `.sops` files as `binary` in `.gitattributes`.
- **Declarative enforcement**: if a WinGet DSC resource can represent desired
  Windows state, prefer adding it to `system.dsc.yml` or `user.dsc.yml` rather
  than introducing new imperative commands in `bootstrap.ps1` or `apply.ps1`.
- **Declarative first**: imperative code in `src/scripts/apply.sh` and
  `src/hosts/windows/apply.ps1` is treated as a bug. If desired state can be
  represented in Nix modules or WinGet DSC resources, move it there.
- **Windows imperative safety**: when imperative Windows logic is unavoidable,
  keep all edits strictly managed-scope, fail fast on unsafe state, and enforce
  idempotency for both configuration and deconfiguration paths.
- **POSIX shared config**: any setting duplicated between
  `src/hosts/macbook/` and `src/hosts/nixos/` (for example Nix experimental
  features, system Zsh enablement, sudo timeout policy, or shared SOPS key
  sources) should be centralized in `src/modules/*.nix` and imported by both
  hosts.
- **Parity-first feature scope**: when adding or changing a capability, audit
  macOS, NixOS, and Windows first, then implement parity on as many hosts as
  practical in the same change. For platform-specific exceptions, add a short
  WHY comment in code. See
  `.agents/instructions/cross-host-feature-parity.instructions.md`.
- **Feature-by-feature parity review**: when reducing parity debt, review
  existing capabilities one-by-one and record each decision as implement now,
  already in parity, or not practical yet (with a short WHY in code).
- **JIT secrets**: do not materialize secrets globally in orchestration
  wrappers. Materialize secrets only in the module/resource that requires them
  (for example Home Manager activation hooks or targeted Windows module calls).
- **SOPS machine recipients**: keep `.sops.yaml` `keys.age_devices` scoped to
  real per-machine recipients (no placeholders), shared across hosts/files
  rather than host-class partitions, with the primary personal SSH recipient as
  the final fallback entry in that list. Keep `keys.primary_gpg` as the global
  GPG backup recipient for all encrypted files.
  When adding or removing a machine, rewrap every encrypted file
  (`src/secrets/*.yml` and `src/assets/wallpapers/*.sops`) with
  `sops updatekeys`.
- **Sorting**: always sort items in any list (package lists, import lists,
  shell alias lists, shell completions, environment variable blocks) and any
  configuration block that lacks a natural semantic order. Alphabetical
  ascending order is the default. Do not sort items whose order is load-order
  or semantically significant (e.g. `boot.initrd.availableKernelModules`,
  module import lists where one module must precede another).
- **Scheduled task time slots**: when adding or updating any recurring background
  task (launchd `StartCalendarInterval`, systemd `OnCalendar`, Task Scheduler
  trigger, etc.) use these canonical fire times: daily → 00:00; weekly → Sunday
  00:00; monthly → first day of the month at 00:00. Do not use arbitrary
  off-peak times (e.g. 03:00); 00:00 is the repository-wide standard.
- **Naming style**: avoid `nucleus` branding prefixes in new identifiers
  (activation names, helper names, options, scripts) unless a prefix is needed
  for external integration or collision avoidance.
- **UI policy: minimal chrome, full capability**: prefer reducing persistent UI
  chrome (for example auto-hide surfaces, hidden optional menu/task controls,
  and trimmed recents) when equivalent keyboard or command access remains.
  Keep high-signal context visibility enabled (for example file extensions,
  hidden files, status/path bars, and explicit file metadata) unless there is a
  concrete reason not to. When hiding anything that can affect discoverability
  or safety, add a short WHY comment and note the alternate access path.
- **Open-source font baseline**: keep cross-host typography declarative and
  open-source only. Provide shared Latin sans/serif/monospace + Nerd Font
  coverage and CJK coverage (Simplified + Traditional) across macOS, NixOS,
  and Windows using one canonical font inventory.
- **Atomic commits**: make one commit per coherent aspect of a change (one
  bug fix, one new feature, one refactor, one docs update). Commit as soon
  as one aspect is complete and validated before beginning the next. Never
  mix unrelated aspects in a single commit; reviewers and bisect depend on
  each commit being independently meaningful.
- **No error hiding**: never use `2>/dev/null`, `>/dev/null 2>&1`,
  unconditional `|| true` on a command that should succeed, PowerShell
  `-ErrorAction SilentlyContinue`, or `2>$null` to silence meaningful
  failures. These patterns hide the root cause of bugs and make broken
  activations appear successful. Error suppression is only acceptable when
  all three conditions hold: (1) the failure is genuinely expected and benign
  in the specific context (for example `pgrep` existence probes or
  `ssh-add -D` when no agent is running), (2) the suppression is accompanied
  by an explicit inline comment stating WHY it is intentional, and (3) the
  result or exit code is checked afterward so unexpected failures are still
  caught. Prefer `if ! cmd; then echo "..." >&2; fi` over bare `|| true`,
  and place `|| true` outside command substitutions (`var=$(cmd) || true`)
  rather than inside (`var=$(cmd 2>/dev/null || true)`) so stderr is never
  discarded silently.

## Package Management Strategy

### Package Selection Policy (macOS)

When a package exists in both nixpkgs and Homebrew, agents must apply the
following logic:

1. **CLI Tools**: Must use `nixpkgs`. Never install CLI tools via Homebrew
   unless the Nix version is broken on Darwin.
2. **GUI Apps**: Must use `homebrew.casks`. Nix-installed GUI apps are
   discouraged due to Spotlight and permission issues (unless mac-app-util is
   explicitly configured).
3. **Hardware/Drivers**: Use Homebrew. Any tool requiring kernel extensions or
   deep system integration (for example `bclm`) should be managed via Homebrew.
4. **Symmetry**: When adding a package, check whether a Windows equivalent
   exists in `src/hosts/windows/system.dsc.yml` to maintain cross-platform
   parity.

### Channel Preference Policy (All Platforms)

When an application offers a preview, beta, canary, or insider release
channel, **prefer that channel over the stable release** on all platforms.
This keeps the managed environment at the leading edge of each tool and
ensures consistent behaviour with the upstream development track.

Apply this rule when:

- A dedicated preview/beta/canary/insider package exists in the relevant
  package manager for that platform.
- The preview channel is at minimum functional (not severely broken).

Examples already following this policy:

- Discord: `discord@canary` (macOS cask / Windows WinGet `Discord.Discord.Canary`)
- Google Chrome: `google-chrome@canary` (macOS cask / Windows `Google.Chrome.Canary`)
- VS Code: `visual-studio-code@insiders` / `Microsoft.VisualStudioCode.Insiders`
- Telegram: `telegram-desktop@beta` / `Telegram.TelegramDesktop.Beta`
- WhatsApp: `whatsapp@beta`
- Windows Terminal: `Microsoft.WindowsTerminal.Preview`

When a preview channel is **not available or not viable** for a specific
platform, use the stable release and add a short inline `# WHY` comment
explaining the exception.

Agents must apply this rule when adding or updating any package on any
platform. When reviewing existing package declarations, flag stable
entries that have an available preview/beta channel as parity debt.

### VS Code Symmetry Protocol

For Visual Studio Code, keep one declarative source of truth in
`src/modules/editors.nix` while letting the installation backend pivot by OS.

1. **Conditional backend**:
   - Non-Darwin hosts use nixpkgs binaries (`pkgs.vscode`,
     `pkgs.vscode-insiders`).
   - Darwin hosts keep VS Code/Insiders in `src/modules/core.nix`
     `overlappingPackages` and resolve backend through
     `nucleus.macos.packageSelection` (global backend + per-package overrides).
   - Do not hard-code VS Code casks into `staticManagedCasks`; when backend
     resolves to Homebrew they must flow through
     `config.nucleus.macos.generatedHomebrew.casks`.
2. **Shared declarative settings**:
   - Define one shared settings attrset in `src/modules/editors.nix`.
   - Write identical JSON to both stable and insiders user-settings paths on
     Linux (`~/.config/Code...`) and macOS
     (`~/Library/Application Support/Code...`).
3. **Darwin extension bridge**:
   - Homebrew app bundles read extensions from `~/.vscode/extensions` and
     `~/.vscode-insiders/extensions`.
   - Maintain a Home Manager activation entry that symlinks those paths to the
     Nix-managed extension directory in the store.

Before concluding VS Code changes, verify: both channels remain backend-selectable
via `core.nix` package-selection options; no VS Code casks are hard-coded into
`staticManagedCasks`; stable and insiders `settings.json` share the same source;
Darwin bridge symlinks only apply when the backend resolves to Homebrew.

### Security Invariants (macOS)

- **Security Invariant: Instant Lock** — always maintain
  `com.apple.screensaver.askForPasswordDelay = 0` and
  `com.apple.screensaver.askForPassword = true` in the macOS host
  configuration. Any attempt to increase this delay or disable password
  requirement is a security regression.
- **Activation Invariant: Manual Instructions Last** —
  `src/modules/macos.nix` `home.activation.displayHostManualInstructions` must
  stay the final activation step. It must depend on every other macOS/Home
  Manager activation entry in that module, and any newly added activation step
  must be added to its dependency list in the same change.
- **Activation Invariant: Dev Repos After Secrets** —
  `src/modules/dev-repos.nix` `home.activation.devReposProvision` must stay
  after the secret-materialization activations from `src/modules/secrets.nix`
  (`waitForSopsSecrets`, `gitIdentityFromSops`, `gpgImport`, `sshKeyAdopt`,
  `verifySecretDecryption`) so Git-over-SSH provisioning always sees imported
  keys and the final verified secret state before any clone/update runs.
  Windows `src/hosts/windows/apply.ps1` must keep `Sync-DevRepo` after
  `Sync-GitAndSshConfig` so all hosts converge dev repos after the same
  secret/key setup phase.
- **Manual-Step Visibility Invariant** — whenever a feature requires a user
  one-time action that cannot be automated safely (for example opening an app to
  finish helper/CLI installation or granting first-run permissions), add the
  exact step to the host manual document (for example
  `src/hosts/macbook/MANUAL.md`) in the same change so activation output stays
  actionable.
- **Drift Reset Invariant: Manual Only** — keep macOS preference-domain purge
  logic (`purge-managed-user-preferences`, driven by
  `src/modules/macos.nix` `resetUserPreferenceDomains`) as a user-invoked
  command, not an automatic activation step.
- **BetterDisplay Free-Tier Invariant** — macOS display automation must avoid
  BetterDisplay Pro-only operations. Do not rely on features that require Pro
  (for example connection toggles for non-virtual displays or other gated
  controls); prefer free-tier-compatible virtual-screen workflows.
- **Battery Charge-Limit Invariant (macOS 15+)** — do not rely on `bclm` on
  macOS 15 or newer because entitlement enforcement breaks it. Prefer the
  `battery` app/CLI workflow for maintaining an 80% charge cap on Apple
  Silicon hosts.
- **Artifact Suppression Invariant (macOS)** — keep
  `com.apple.desktopservices.DSDontWriteNetworkStores = true` and
  `com.apple.desktopservices.DSDontWriteUSBStores = true` in declarative
  defaults to suppress `.DS_Store` creation on network and removable volumes.

### Security Invariants (Windows)

- **Long Path Invariant** — always keep
  `HKLM\System\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1`
  in `src/hosts/windows/system.dsc.yml`. This prevents Nix/Git path failures
  on deep directory trees.

- **Managed Wallpaper Source Invariant** — keep wallpaper paths sourced from
  declaratively materialized files in `%USERPROFILE%\Pictures\wallpapers`
  (via `Sync-NucleusWallpapers`), not arbitrary unmanaged file paths.

### Shell Strategy (POSIX Hosts)

- For macOS and NixOS hosts, keep **Zsh** as the default interactive and login
  shell. Do not introduce Fish or Nushell as defaults in shared modules.
- Keep `programs.zsh.enable = true` at the system layer for both hosts and keep
  managed user login shells on `pkgs.zsh`.
- Keep `programs.direnv` with `nix-direnv` enabled in shared shell config so
  Flake/devShell environments auto-load consistently in Zsh sessions.

### Wallpaper Gallery Policy

The `src/modules/wallpapers.nix` activation hook manages desktop wallpapers as
a rotating gallery, never as a single static file.

1. **Direct file application ban**: agents must never call `osascript` or
   `gsettings` targeting a single `.jpg` or `.png` path. All desktop background
   commands must target either the gallery folder (macOS) or the generated XML
   file (GNOME).
2. **macOS**: `set picture of aDesktop` must point to the decrypted-wallpapers
   **folder** (`~/Pictures/wallpapers`), with `picture rotation` set to `1`,
   `change interval` set to `600.0` (10 minutes), and `random order` set to
   `true`.
3. **GNOME**: the activation hook must regenerate `nucleus-gallery.xml` on
   every run, listing every image in `~/Pictures/wallpapers/` with alternating
   `<static>` (595 s) and `<transition type="overlay">` (5 s) elements that
   loop back to the first image. `picture-uri` must point to this XML file.
4. **Windows**: user wallpaper registry state must point to a path generated
   from declaratively managed wallpaper assets (`assets/wallpapers/*.sops`
   materialized to `%USERPROFILE%\Pictures\wallpapers`). Keep the
   `__NUCLEUS_ACTIVE_WALLPAPER__` replacement flow in the Windows apply path so
   DSC always receives a managed file path.
5. **Stale cleanup**: before applying the gallery, delete any file in
   `~/Pictures/wallpapers/` (excluding `*.xml`) that has no corresponding
   `assets/wallpapers/$name.sops` source in the repository (Windows equivalent:
   `Remove-NucleusStaleWallpapers`).

## Refactoring Guardrails

- **Pre-flight check rule**: before proposing or executing edits, verify target
  paths on disk and list all files that will be changed.
- **Pre-flight wiring check**: before concluding refactors that add new
  `.json`, `.md`, `.nix`, or `.ps1` fragments, verify each new file is wired
  into the relevant module/entrypoint (`readFile`/imports/dot-sourcing) and
  that no fragment is orphaned.
- **Cross-platform symmetry rule**: when adding a capability that exists on
  both Unix and Windows (for example secrets, fonts, or wallpapers), add or
  update both implementations in the same change:
  - Unix side under `src/modules/*.nix`
  - Windows side under `src/hosts/windows/modules/*.ps1`
- **Windows module enforcement**: all reusable PowerShell functions must live
  under `src/hosts/windows/modules/*.ps1` with lowercase filenames; keep
  `src/hosts/windows/apply.ps1` orchestration-only.

## Key References

- `AGENTS.md` — workspace-wide defaults
- `.agents/instructions/*.instructions.md` — focused authoring rules by file type
- `.agents/prompts/commit-staged.prompt.md` and
  `.opencode/commands/commit-staged.prompt.md` — mirrored commit workflow prompt
- `opencode.jsonc` — instruction and skill discovery
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
