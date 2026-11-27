---
description: "Use when authoring or editing WinGet DSC configuration files."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/Windows/**/*.yml, src/hosts/Windows/**/*.json"
---

# WinGet DSC authoring

`system/*.dsc.yml` applies to every user; `user/*.dsc.yml` is per user and listed in `dscConfigFiles` in `src/users/<username>/windows.json`. One file per subsystem; never mix concerns. `src/hosts/Windows/apply.ps1` applies files in order.

Each document has top-level `properties` with `configurationVersion: 0.2.0` and a `resources:` list. Every entry needs `resource:` (fully qualified `Namespace/ResourceName`), `directives.description:`, and `settings:`.

Resource group order within a file: packages (`Microsoft.WinGet.Client/Package`), system settings (`Microsoft.Windows.Settings/*`), registry (`Microsoft.Windows.Registry/*`), environment (`Microsoft.Windows.Environment/*`), then script (`PSDscResources/Script`). Sort alphabetically, case-folded, inside each group by `settings.id` (packages) or `settings.valueName`/`settings.name`; group integrity beats cross-type alphabetical order.

Use only `.yml` and `source: winget` on every package. Verify canonical WinGet ids with `winget search`; prefer named ids over Store-generated ones and document why when only a generated id exists. `src/hosts/Windows/system/winget-packages.json` is generated from `src/modules/core.nix`; regenerate with `install -m 644 "$(nix build --no-link --print-out-paths ./src#winget-packages)" src/hosts/Windows/system/winget-packages.json`, never hand-edit. It is an aarch64-darwin derivation: macOS step 3 compares bytes, nix-tests compares parsed entries and pins root-key order on POSIX. Prefer preview/canary channels (`AGENTS.md`); document exceptions in `directives.description:`. Registry values need `valueType` (`DWord`, `String`, ...); env vars use scope `User` or `Machine`, prefer `User`; use `%USERPROFILE%` for user home in values. Preserve visibility defaults; when reducing UI chrome, state the tradeoff and remaining access path in `directives.description:`.

`winget configure` auto-installs the PSGallery module each `resource:` needs. Prefer dot-sourced `src/platforms/Windows/modules/*.ps1` over `PSDscResources/Script`, which is valid only when `TestScript` is a simple reliable boolean, no native resource covers the state, PATH is guaranteed or prepended in both scripts, and it buys idempotency, `dependsOn`, or `--what-if`. DSC runs in a fresh session, so `~\.cargo\bin` and `~\scoop\shims` may be absent; skip the Script resource when PATH cannot be fixed reliably. Dot-source from `SetScript` with a repo-relative path anchored on `$PSScriptRoot`:

```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$repoRoot\src\platforms\Windows\modules\your-module.ps1"
Your-Function
```

Declarative resources already cover secrets, wallpaper, SSH bootstrap, VS Code extensions, git/SSH config, shell profiles, service lifecycle, `powercfg.exe`, and post-apply health checks. `cargo-cache` is managed by `Invoke-CargoBinstallSetup`, not DSC, with no WinGet id; `scripts/gc.ps1` skips pruning when absent.

Scoop installs user-space CLI tools with no WinGet id into `%USERPROFILE%\scoop\` without admin. `ScoopInstall` Script resource downloads the commit-pinned `ScoopInstaller/Install` script, checks SHA256, and keeps `Git.Git` as `dependsOn`. `Invoke-ScoopSetup` registers `fonts` and reconciles apps after DSC; never reconcile with `PSDscResources/Script` because `scoop` is absent from DSC PATH. Tools missing from WinGet and public buckets get `src/modules/scoop-manifests/<name>.json` plus `bucket: "nucleus"` in `desired.json`; manifests follow Scoop's published spec, NSIS installers use `installer.script` with `/S`, `$schema` points at Scoop's schema for step 7, and installs guard with `Test-Path` on the shim, not `Get-Command`. `Invoke-CargoBinstallSetup.ps1` handles `cargo-cache` and `pay-respects`, keeping `~\.config\nucleus\cargo-binstall-packages.json`, using `cargo binstall --no-confirm` and `cargo uninstall`.

Windows imperative recovery rules are in `cross-host-feature-parity.md#windows-imperative-recovery`.

Dry run with `winget configure --what-if .\src\hosts\Windows\system\*.dsc.yml` and the same for `user\`; full apply needs elevation plus `--accept-configuration-agreements`, which `scripts/bootstrap.ps1` passes.

Avoid duplicate entries (`system/packages.dsc.yml` is the WinGet baseline), hard-coded versions unless pinning, and commented-out resources. PowerShell functions are verb-noun and descriptive, with no `nucleus*` prefix unless disambiguation requires it (`Sync-WallpaperInventory`, not `Sync-NucleusWallpapers`).
