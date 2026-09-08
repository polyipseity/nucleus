---
description: "Use when authoring or editing WinGet DSC configuration files under src/hosts/Windows/. Covers DSC v3 YAML structure, resource ordering, sorting, and safe authoring patterns for this repository."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/Windows/**/*.yml"
---

# WinGet DSC Authoring

## Architecture and file layout

**System** (`system/*.dsc.yml`): applied to every user. **User** (`user/*.dsc.yml`): applied per-user via `dscConfigFiles` in `src/users/<username>/windows.json`. One file per subsystem; do not mix resources from different concerns.

**System**: `scheduler`, `developer-mode`, `firewall`, `taskbar`, `computer-name`, `long-paths`, `storage-sense`, `font-substitutes`, `remote-desktop`, `packages`.
**User**: `wallpaper`, `screen-saver`, `explorer`, `shell`, `env`, `context-manual`, `context-optimize-pdf`.

Applied in-order by `src/hosts/Windows/apply.ps1`. Helper logic in `src/platforms/Windows/modules/*.ps1`; DSC files stay as state declarations.

## DSC v3 document structure

Top-level `properties` key with `configurationVersion: 0.2.0` and `resources:` list. Each entry needs `resource:` (fully qualified `Namespace/ResourceName`), `directives.description:`, and `settings:`.

## Resource groups and ordering

Order within each file: (1) packages (`Microsoft.WinGet.Client/Package`), (2) system settings (`Microsoft.Windows.Settings/*`), (3) registry (`Microsoft.Windows.Registry/*`), (4) environment variables (`Microsoft.Windows.Environment/*`), (5) script (`PSDscResources/Script` — rare, for imperative steps with no declarative alternative).

Sort alphabetically within each group by `settings.id` (packages) or `settings.valueName`/`settings.name` (others). Group integrity beats cross-type alphabetical ordering.

## Authoring rules

- `.yml` extension only; specify `source: winget` for all packages.
- Use canonical WinGet package identifiers (verified via `winget search`). Prefer named IDs over opaque Store-generated IDs; document rationale when only generated IDs exist.
- Prefer preview/canary channel per `AGENTS.md` Channel Preference Policy; document exceptions in `directives.description:`.
- Registry values must include `valueType` (`DWord`, `String`, etc.). Environment variables: scope as `User` or `Machine` (prefer `User`).
- Use `%USERPROFILE%` for user home in `value` strings.
- UI settings: allow reduced chrome when keyboard/command access remains. Preserve visibility defaults (hidden files, extensions, status bars) unless justified. When reducing visibility, explain the tradeoff and alternate access path in `directives.description:`.

## PowerShell DSC resource modules

`winget configure` auto-installs required PowerShell Gallery modules per `resource:` identifier — no separate install step.

Use `PSDscResources/Script` only when no declarative resource covers the state. Prefer `src/platforms/Windows/modules/*.ps1` (dot-sourced by `apply.ps1`) for complex logic.

**PATH caveat:** DSC runs in a fresh PowerShell session — user-level tool directories (`~\.cargo\bin`, `~\scoop\shims`) may be absent. Any `PSDscResources/Script` block invoking a user-installed binary must prepend the relevant path in `SetScript` and `TestScript`. If that cannot be done reliably, do not add the resource.

**cargo-cache:** managed by `Invoke-CargoBinstallSetup` (not DSC) — no WinGet ID. Runs after DSC in `apply.ps1`. `scripts/gc.ps1` skips pruning when absent.

## PSDscResources/Script resource

Wraps imperative logic in a declarative shell: idempotency (`TestScript` gates `SetScript`), dependency ordering (`dependsOn`), `--what-if` support, and drift detection via re-evaluation.

### YAML structure

```yaml
- resource: PSDscResources/Script
  id: ExampleResourceId # required when other resources use dependsOn
  directives:
    description: >-
      WHY this resource exists and what invariant it maintains.
  settings:
    GetScript: |
      return @{ Result = if (Test-Path "$env:USERPROFILE\.example") { "Present" } else { "Absent" } }
    TestScript: |
      return Test-Path "$env:USERPROFILE\.example"
    SetScript: |
      New-Item -Path "$env:USERPROFILE\.example" -ItemType Directory -Force
```

### Candidacy criteria (all four required)

1. Reliable `TestScript` (simple boolean check).
2. No native DSC resource covers the same state.
3. PATH is guaranteed or explicitly prepended in both `TestScript` and `SetScript`.
4. DSC provides a benefit (idempotency, `dependsOn`, `--what-if`) that `apply.ps1` alone does not.

### Path resolution in DSC context

When dot-sourcing repo modules from `SetScript`, use an explicit repo-relative path anchored to `$PSScriptRoot` or a known env var:

```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$repoRoot\src\hosts\windows\modules\your-module.ps1"
Your-Function
```

### When NOT to use PSDscResources/Script

Skip for: unreliable PATH, complex state, or declarative alternatives — secrets, wallpaper provisioning, SSH key bootstrap, VS Code extensions, Git/SSH config, shell profiles, service lifecycle, `powercfg.exe` power policy, post-apply health checks.

## Package manager preference hierarchy

1. **WinGet** — preferred for any package with a WinGet ID.
2. **Scoop** — portable CLI tools not in WinGet. No admin required; installs to `%USERPROFILE%\scoop\`.
3. **cargo binstall** — Rust CLI tools not in WinGet or Scoop. Downloads prebuilt binaries.
4. **bun** — last resort for JS/npm-only tools. Binaries go to `%USERPROFILE%\.bun\bin`.

POSIX equivalent: `nixpkgs > cargo binstall > bun`. Document departures with WHY comments.

## Scoop

User-space package manager for CLI tools without WinGet IDs. Installs to `%USERPROFILE%\scoop\`, no admin required.

### Declaring Scoop in system/packages.dsc.yml

Install Scoop itself via WinGet (package ID `Scoop.Scoop`). Scoop requires `Git.Git` for bucket management; confirm it appears in the packages list. Use `dependsOn` to enforce ordering:

```yaml
- resource: Microsoft.WinGet.Client/Package
  id: ScoopInstall
  directives:
    description: >-
      Scoop user-space package manager for portable CLI utilities not
      available via WinGet (e.g. cargo-binstall).  Requires Git for bucket
      management; declared after Git.Git via dependsOn.
  settings:
    id: Scoop.Scoop
    source: winget
  dependsOn:
    - GitInstall # the id: of the Git.Git package entry
```

### Scoop bucket and app provisioning

Do not use `PSDscResources/Script` for Scoop management — `scoop` is not on PATH immediately after WinGet installs it. Use `src/platforms/Windows/modules/Invoke-ScoopSetup.ps1` instead, called by `apply.ps1` after DSC completes.

### Idempotency in Scoop operations

Guard all installs with existence checks (Test-Path on the shim, not Get-Command -- PATH may not be set in the DSC session).

### cargo binstall for Rust tools

After Scoop installs cargo-binstall, `src/platforms/Windows/modules/Invoke-CargoBinstallSetup.ps1` manages Rust CLI tools that have no WinGet or Scoop equivalent (e.g. `cargo-cache`, `pay-respects`). It maintains a desired-state list and a manifest at `~\.config\nucleus\cargo-binstall-packages.json`; on each apply it installs additions via `cargo binstall --no-confirm` and removes deletions via `cargo uninstall`.

## Imperative recovery safety (Windows modules)

See [Imperative recovery safety (Windows)](cross-host-feature-parity.instructions.md#imperative-recovery-safety-windows) for the full policy.

## Validation

Dry-run: `winget configure --what-if .\src\hosts\windows\*.dsc.yml` for each file. Full apply requires elevated session + `--accept-configuration-agreements` (the `scripts/bootstrap.ps1` wrapper passes both).

## What to avoid

- No duplicate entries across DSC files. `system-packages.dsc.yml` is the WinGet baseline; `system.dsc.yml` for machine settings.
- No hard-coded version strings unless pinning intentionally.
- No commented-out resources — remove or track separately.

## Naming

No repository-brand prefixes (`nucleus*`) in new PowerShell function names unless needed for disambiguation. Use descriptive verb-noun patterns (`Sync-WallpaperInventory`, not `Sync-NucleusWallpapers`).
