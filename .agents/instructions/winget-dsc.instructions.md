---
description: "Use when authoring or editing WinGet DSC configuration files under src/hosts/Windows/. Covers DSC v3 YAML structure, resource ordering, sorting, and safe authoring patterns for this repository."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/Windows/**/*.yml, src/hosts/Windows/**/*.json"
---

# WinGet DSC authoring

## Architecture and file layout

`system/*.dsc.yml` applies to every user. `user/*.dsc.yml` applies per user, listed in `dscConfigFiles` in `src/users/<username>/windows.json`. One file per subsystem; never mix resources from different concerns. `src/hosts/Windows/apply.ps1` applies them in order.

## DSC v3 document structure

Top-level `properties` key with `configurationVersion: 0.2.0` and a `resources:` list. Each entry needs `resource:` (fully qualified `Namespace/ResourceName`), `directives.description:`, and `settings:`.

## Resource groups and ordering

Within a file: (1) packages (`Microsoft.WinGet.Client/Package`), (2) system settings (`Microsoft.Windows.Settings/*`), (3) registry (`Microsoft.Windows.Registry/*`), (4) environment variables (`Microsoft.Windows.Environment/*`), (5) script (`PSDscResources/Script`). Sort alphabetically inside each group by `settings.id` (packages) or `settings.valueName`/`settings.name` (others). Group integrity beats cross-type alphabetical ordering.

## Authoring rules

- `.yml` extension only; `source: winget` on every package.
- Use canonical WinGet identifiers, verified with `winget search`. Prefer named IDs over opaque Store-generated IDs; document the rationale when only a generated ID exists.
- `src/hosts/Windows/system/winget-packages.json` is generated from the managed package registry in `src/modules/core.nix`. Never hand-edit it; regenerate with `install -m 644 "$(nix build --no-link --print-out-paths ./src#winget-packages)" src/hosts/Windows/system/winget-packages.json`. That derivation is an aarch64-darwin build, so the macOS-only check step 3 is the only byte-exact comparison; the nix-tests step compares the parsed entry set on every POSIX host.
- Prefer preview/canary channel per `AGENTS.md` channel policy; document exceptions in `directives.description:`.
- Registry values need `valueType` (`DWord`, `String`, ...). Environment variables: scope as `User` or `Machine`, prefer `User`.
- Use `%USERPROFILE%` for user home in `value` strings.
- Preserve visibility defaults (hidden files, extensions, status bars). When reducing UI chrome, state the tradeoff and the remaining access path in `directives.description:`.

## PowerShell DSC resource modules

`winget configure` auto-installs the PowerShell Gallery module each `resource:` identifier needs.

Prefer `src/platforms/Windows/modules/*.ps1` (dot-sourced by `apply.ps1`) over `PSDscResources/Script` for complex logic. Use `PSDscResources/Script` only when all four hold:

1. `TestScript` is a simple, reliable boolean check.
2. No native DSC resource covers the state.
3. PATH is guaranteed or explicitly prepended in both `TestScript` and `SetScript`.
4. It buys idempotency, `dependsOn`, or `--what-if` that `apply.ps1` alone does not.

**PATH caveat:** DSC runs in a fresh PowerShell session, so user-level tool directories (`~\.cargo\bin`, `~\scoop\shims`) may be absent. If a `PSDscResources/Script` block invokes a user-installed binary and the path cannot be prepended reliably in both scripts, do not add the resource.

When dot-sourcing repo modules from `SetScript`, anchor an explicit repo-relative path on `$PSScriptRoot`:

```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$repoRoot\src\platforms\Windows\modules\your-module.ps1"
Your-Function
```

Skip `PSDscResources/Script` when PATH is unreliable or the state is complex. Declarative resources already cover secrets, wallpaper provisioning, SSH key bootstrap, VS Code extensions, Git/SSH config, shell profiles, service lifecycle, `powercfg.exe` power policy, and post-apply health checks.

`cargo-cache` is managed by `Invoke-CargoBinstallSetup`, not DSC, and has no WinGet ID. `scripts/gc.ps1` skips pruning when it is absent.

## Scoop

Scoop installs user-space CLI tools with no WinGet ID into `%USERPROFILE%\scoop\`, no admin required. Install Scoop itself via WinGet (`Scoop.Scoop`); it needs `Git.Git` for bucket management, so declare the dependency with `dependsOn`.

Never manage Scoop with `PSDscResources/Script`: `scoop` is not on PATH right after WinGet installs it. Use `src/platforms/Windows/modules/Invoke-ScoopSetup.ps1`, which `apply.ps1` calls after DSC completes.

For a tool absent from WinGet and the public buckets (`main`, `extras`), write a manifest in `src/modules/scoop-manifests/<name>.json` and add `bucket: "nucleus"` to its `desired.json` entry. `Invoke-ScoopSetup` copies the manifests into `~\scoop\buckets\nucleus\` and installs with `scoop install nucleus/<name>`. Manifest format follows [Scoop's app manifest spec](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests); for NSIS installers use the `installer.script` block with the `/S` silent flag, and set `$schema` to Scoop's published schema for step 7 validation. Guard installs with `Test-Path` on the shim, never `Get-Command`.

`src/platforms/Windows/modules/Invoke-CargoBinstallSetup.ps1` handles Rust CLI tools with no WinGet or Scoop equivalent (`cargo-cache`, `pay-respects`). It keeps a desired-state list at `~\.config\nucleus\cargo-binstall-packages.json` and runs `cargo binstall --no-confirm` for additions, `cargo uninstall` for removals.

## Imperative recovery safety (Windows modules)

See [Imperative recovery safety (Windows)](cross-host-feature-parity.instructions.md#imperative-recovery-safety-windows).

## Validation

Dry run: `winget configure --what-if .\src\hosts\Windows\system\*.dsc.yml` and the same for `user\`. A full apply needs an elevated session plus `--accept-configuration-agreements`; the `scripts/bootstrap.ps1` wrapper passes both.

## What to avoid

- Duplicate entries across DSC files. `system/packages.dsc.yml` is the WinGet baseline, `system/*.dsc.yml` holds machine settings.
- Hard-coded version strings unless pinning on purpose.
- Commented-out resources. Remove them or track them elsewhere.

## Naming

No `nucleus*` prefix on PowerShell function names unless disambiguation demands it. Verb-noun, descriptive: `Sync-WallpaperInventory`, not `Sync-NucleusWallpapers`.
