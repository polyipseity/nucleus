---
description: "Use when authoring or editing WinGet DSC configuration files under src/hosts/Windows/. Covers DSC v3 YAML structure, resource ordering, sorting, and safe authoring patterns for this repository."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/Windows/**/*.yml"
---

# WinGet DSC Authoring

## Architecture: universal vs per-user DSC files

DSC files in this repo split into two categories:

- **System files** (`system/*.dsc.yml`): applied universally to every user on the machine. Currently: `scheduler`, `developer-mode`, `firewall`, `taskbar`, `computer-name`, `long-paths`, `storage-sense`, `font-substitutes`, `remote-desktop`, `packages`.
- **User files** (`user/*.dsc.yml`): applied per-user based on each user's `dscConfigFiles` list in `src/users/<username>/windows.json`. Currently: `wallpaper`, `screen-saver`, `explorer`, `shell`, `env`, `context-manual`, `context-optimize-pdf`.

Mapping: system files are always applied; user files must be explicitly listed per user. See `src/users/polyipseity/windows.json` (and `src/users/default/windows.json` fallback) for the active user-to-file mapping.

## File location and purpose

One DSC file per subsystem or concern. Do not mix resources from different subsystems.

**System** (`system/*.dsc.yml`): `scheduler`, `developer-mode`, `firewall`, `taskbar`, `computer-name`, `long-paths`, `storage-sense`, `font-substitutes`, `remote-desktop`, `packages`.
**User** (`user/*.dsc.yml`): `wallpaper`, `screen-saver`, `explorer`, `shell`, `env`, `context-manual`, `context-optimize-pdf`.

Applied in-order by `src/hosts/Windows/apply.ps1`. Helper logic in `src/platforms/Windows/modules/*.ps1`; DSC files stay as state declarations, not script logic.

## DSC v3 document structure

Top-level `properties` key with `configurationVersion: 0.2.0` and `resources:` list. Each entry needs `resource:` (fully qualified `Namespace/ResourceName`), `directives.description:`, and `settings:`.

## Resource groups and ordering

Order within each file: (1) packages (`Microsoft.WinGet.Client/Package`), (2) system settings (`Microsoft.Windows.Settings/*`), (3) registry (`Microsoft.Windows.Registry/*`), (4) environment variables (`Microsoft.Windows.Environment/*`), (5) script (`PSDscResources/Script` — rare, for imperative steps with no declarative alternative).

Sort alphabetically within each group by `settings.id` (packages) or `settings.valueName`/`settings.name` (others). Group integrity beats cross-type alphabetical ordering.

## Authoring rules

- Always use `.yml` extension for WinGet DSC manifests; do not create long-extension YAML filenames in `src/hosts/Windows/`.
- Always specify `source: winget` for `Microsoft.WinGet.Client/Package` entries, even if it is technically the default.
- Use the canonical WinGet package identifier (verified via `winget search`) rather than a display name or URL.
- When a WinGet package has a Preview or Canary variant (for example `Microsoft.WindowsTerminal.Preview` vs `Microsoft.WindowsTerminal`), prefer the preview channel per the repository-wide Channel Preference Policy in `AGENTS.md`. Use the stable ID only when the preview channel is unavailable or severely broken; document the exception with a `directives.description:` note.
- Prefer human-readable named package IDs over opaque Microsoft Store-generated IDs when a named ID exists.
- When a package only exposes a generated ID, use it and document the rationale in `directives.description:`.
- For registry values, always include `valueType` (`DWord`, `String`, etc.) to prevent ambiguous interpretation.
- Scope environment variables as `User` or `Machine`; prefer `User` unless the setting must be machine-wide.
- Use `%USERPROFILE%` rather than a hard-coded path for the user's home directory in `value` strings.
- For UI/discoverability settings, apply a minimal-chrome rule: allow reduced persistent chrome (hidden optional taskbar controls, compact surfaces) when equivalent keyboard/command access remains available.
- Preserve high-signal visibility defaults (hidden files, file extensions, status bars, navigation-pane folder visibility) unless a concrete workflow reason justifies reducing visibility.
- If a choice reduces visibility or masks controls, explain the tradeoff in `directives.description:` with a short WHY and the alternate access path (shortcut, command, or menu route).

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

All Scoop install/bucket operations must be guarded:

```powershell
if (-not (scoop bucket list | Select-String -Quiet "^extras$")) {
    scoop bucket add extras
}
$cbBin = Join-Path $scoopShims "cargo-binstall.cmd"
if (-not (Test-Path $cbBin)) {
    # cargo-binstall has no WinGet package ID; Scoop main bucket is the
    # preferred source.  Use Test-Path on the shim rather than Get-Command so
    # the check is reliable before ~\scoop\shims is on PATH in this session.
    scoop install cargo-binstall
    if (-not (Test-Path $cbBin)) {
        Write-Error "scoop: cargo-binstall install failed — shim not found after install"
    }
}
```

### cargo binstall for Rust tools

After Scoop installs cargo-binstall, `src/platforms/Windows/modules/Invoke-CargoBinstallSetup.ps1` manages Rust CLI tools that have no WinGet or Scoop equivalent (e.g. `cargo-cache`, `pay-respects`). It maintains a desired-state list and a manifest at `~\.config\nucleus\cargo-binstall-packages.json`; on each apply it installs additions via `cargo binstall --no-confirm` and removes deletions via `cargo uninstall`.

## Imperative recovery safety (Windows modules)

See [Imperative recovery safety (Windows)](cross-host-feature-parity.instructions.md#imperative-recovery-safety-windows) for the full policy.

## Validation

- Test the manifest dry-run on the target machine with:

  ```powershell
  winget configure --what-if .\src\hosts\windows\system.dsc.yml
  winget configure --what-if .\src\hosts\windows\system-packages.dsc.yml
  winget configure --what-if .\src\hosts\windows\user.dsc.yml
  winget configure --what-if .\src\hosts\windows\user-env.dsc.yml
  winget configure --what-if .\src\hosts\windows\user-context.dsc.yml
  ```

- Full application requires an elevated PowerShell session and `--accept-configuration-agreements`.
- The `scripts/bootstrap.ps1` wrapper passes both flags automatically.

## What to avoid

- No duplicate entries across DSC files. `system-packages.dsc.yml` is the WinGet baseline; `system.dsc.yml` for machine settings.
- No hard-coded version strings unless pinning intentionally.
- No commented-out resources — remove or track separately.

## Naming

- Avoid repository-brand prefixes (e.g. `nucleus*`) in new PowerShell function names and filenames unless needed for cross-module disambiguation or external integration points. Use descriptive verb-noun patterns (e.g. `Sync-WallpaperInventory` instead of `Sync-NucleusWallpapers`).
