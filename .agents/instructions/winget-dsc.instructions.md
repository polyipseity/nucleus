---
description: "Use when authoring or editing WinGet DSC configuration files under src/hosts/windows/. Covers DSC v3 YAML structure, resource ordering, sorting, and safe authoring patterns for this repository."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/windows/**/*.yml"
---

# WinGet DSC Authoring

## File location and purpose

- `src/hosts/windows/system.dsc.yml` contains pre-provision system baseline
  resources (packages, machine settings, machine registry).
- `src/hosts/windows/user.dsc.yml` contains post-provision user baseline
  resources (folder layout, user registry, user environment variables).
- They are applied in-order by `src/hosts/windows/apply.ps1`.
- Reusable Windows helper logic is loaded from `src/modules/windows/*.ps1`; DSC
  files should remain state declarations rather than script logic.

## DSC v3 document structure

- The document must have a top-level `properties` key containing exactly:
  - `configurationVersion: 0.2.0`
  - `resources:` — the ordered list of resource declarations.
- Every resource entry must include:
  - `resource:` — fully qualified resource identifier (`Namespace/ResourceName`).
  - `directives.description:` — a brief human-readable explanation of what the
    entry does.
  - `settings:` — the resource-specific configuration values.

## Resource groups and ordering

Organize resources into these logical groups, in this order (within each DSC
file):

1. Package installations (`Microsoft.WinGet.Client/Package`)
2. System settings (`Microsoft.Windows.Settings/*`)
3. Registry tweaks (`Microsoft.Windows.Registry/*`)
4. Environment variables (`Microsoft.Windows.Environment/*`)
5. Script resources (`PSDscResources/Script`) — only for imperative steps that
   cannot be expressed by any declarative resource type; keep these rare

Within each group, sort entries alphabetically by the `settings.id` (for
packages) or `settings.valueName` / `settings.name` (for other resources).

## Sorting

- Within a package group, sort entries alphabetically by `settings.id`.
- Within environment variable or registry groups, sort by `settings.name` or
  `settings.valueName`.
- Do not mix resource types within a group just to maintain strict alphabetical
  ordering across the whole file — group integrity takes priority.

## Authoring rules

- Always use `.yml` extension for WinGet DSC manifests; do not create
  long-extension YAML filenames in `src/hosts/windows/`.
- Always specify `source: winget` for `Microsoft.WinGet.Client/Package`
  entries; do not omit it even if it is technically the default.
- Use the canonical WinGet package identifier (verified via `winget search`)
  rather than a display name or URL.
- When a WinGet package has a Preview or Canary variant (for example
  `Microsoft.WindowsTerminal.Preview` vs `Microsoft.WindowsTerminal`),
  prefer the preview channel per the repository-wide Channel Preference
  Policy in `AGENTS.md`. Use the stable ID only when the preview channel
  is unavailable or severely broken; document the exception with a
  `directives.description:` note.
- Prefer human-readable named package IDs over opaque Microsoft Store-generated
  IDs whenever a named ID exists.
- When a Microsoft Store package only exposes a generated ID, keep using that
  ID and document the rationale in `directives.description:`.
- For registry values, always include `valueType` (`DWord`, `String`, etc.)
  to prevent ambiguous interpretation.
- Environment variable scope must be `User` or `Machine`; prefer `User` unless
  the setting must be machine-wide.
- Use `%USERPROFILE%` rather than a hard-coded path for the user's home
  directory in `value` strings.
- For UI/discoverability settings, apply a minimal-chrome rule: allow reduced
  persistent chrome (for example hidden optional taskbar controls or compact
  surfaces) when equivalent keyboard/command access remains available.
- Preserve high-signal visibility defaults by default (for example hidden files,
  file extensions, status bars, and navigation-pane folder visibility) unless a
  concrete workflow reason justifies reducing visibility.
- If a Windows UI choice reduces visibility or hides controls, explain the
  tradeoff in `directives.description:` with a short WHY and include the
  alternate access path (shortcut, command, or menu route).

## PowerShell DSC resource modules

`winget configure` resolves each `resource: Module/Resource` identifier against
the PowerShell Gallery and **auto-installs** the required module if it is not
already present in `$env:PSModulePath`.  No separate install step is needed —
any `PSDscResources/Script` entry will cause WinGet to download and install the
`PSDscResources` module automatically before invoking the resource.

Use `PSDscResources/Script` only for imperative steps that cannot be expressed
by any declarative resource type.  Prefer moving complex logic to
`src/modules/windows/*.ps1` (dot-sourced by `apply.ps1`) so the DSC file stays
a state declaration rather than a script host.

**When PATH is not guaranteed during DSC execution:**
DSC resources run in a fresh PowerShell session where `$env:PATH` may not
include user-level tool directories (for example `~\.cargo\bin` from a prior
`rustup init` call).  Any `PSDscResources/Script` block that invokes a
user-installed binary must prepend the relevant path explicitly in `SetScript`
and `TestScript`.  If that cannot be done reliably, do not add the resource —
document the gap and rely on a graceful probe in `apply.ps1` or a
`scripts/gc.ps1`-style script instead.

**cargo-cache is managed via cargo-binstall, not `system.dsc.yml`:** `cargo-cache`
has no WinGet package ID and is not in Scoop.  It is installed declaratively by
`Invoke-CargoBinstallSetup` (in `src/modules/windows/cargo-binstall-setup.ps1`)
which runs after the DSC step in `apply.ps1`.  `scripts/gc.ps1` probes for the
binary gracefully and skips pruning when it is absent.

**`winget cache purge` and `winget clean` do not exist** — WinGet has no cache
management subcommands.  Do not add either as a `SetScript` body.

## PSDscResources/Script resource

### Purpose and advantages

Wrapping imperative logic in a `PSDscResources/Script` block makes the
*management* of that logic declarative, even though the code inside remains
imperative. Four concrete benefits:

1. **Idempotency by design** — `TestScript` is the authoritative check;
   `SetScript` only runs when `TestScript` returns `$false`, so no manual
   `if`-guards needed.
2. **Dependency orchestration** — `dependsOn` ensures ordering relative to
   other resources (e.g., run after a package is installed).
3. **`--what-if` support** — `winget configure --what-if` executes `TestScript`
   for all resources and reports what *would* change without applying
   `SetScript`.
4. **Drift detection** — re-running `TestScript` later reveals configuration
   drift without triggering re-installation.

### YAML structure

```yaml
- resource: PSDscResources/Script
  id: ExampleResourceId          # required when other resources use dependsOn
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

### Candidacy criteria — ALL four must hold

Use `PSDscResources/Script` only when:

1. A meaningful `TestScript` can be written — a simple, reliable boolean check
   of the desired state.
2. No native DSC resource (`Microsoft.Windows.Registry`,
   `Microsoft.Windows.Environment`, etc.) already covers the same state.
3. PATH is guaranteed or can be explicitly prepended in both `TestScript` and
   `SetScript`. DSC runs in a fresh PowerShell session where user-level tool
   directories (e.g., `~\.cargo\bin`, `~\scoop\shims`) may not be on PATH.
   Any block invoking a user-installed binary must prepend its directory
   explicitly.
4. Moving to DSC provides a genuine benefit — idempotency, `dependsOn`
   ordering, or `--what-if` reporting — that the existing `apply.ps1` call
   does not already provide.

### Path resolution in DSC context

When dot-sourcing repo modules from `SetScript`, use an explicit repo-relative
path anchored to `$PSScriptRoot` or a known env var rather than assuming the
working directory:

```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$repoRoot\src\modules\windows\your-module.ps1"
Your-Function
```

### When NOT to use PSDscResources/Script

Do **not** use a Script block for:

- **Secrets/SOPS/GPG operations**: PATH dependencies on GPG, complex state,
  explicitly excluded by policy.
- **Wallpaper provisioning**: SOPS decryption, complex multi-file management,
  explicitly excluded by policy.
- **SSH host key bootstrap or registration**: service lifecycle,
  network/git operations, timing-dependent state.
- **VS Code extension management**: `code`/`code-insiders` CLI not guaranteed
  in PATH during DSC execution.
- **Git/SSH config sync**: depends on SOPS-materialized files produced *outside*
  DSC — `dependsOn` cannot model this ordering.
- **Shell profile editing (managed-block pattern)**: complex file editing;
  inline YAML PowerShell would be fragile.
- **Service lifecycle management** (OpenSSH, RDP TermService): no reliable
  boolean `TestScript` without running `Get-Service` inline.
- **`powercfg.exe`-based power policy**: no structured query API; output
  parsing fragile in YAML.
- **Health checks / post-apply probes**: these are assertions, not convergence
  state.

### Audit result for this repository

A full audit of every `apply.ps1` operation against the four candidacy
criteria found **zero candidates**: every operation fails at least one criterion
(complex state, uncertain PATH, existing native resource, or
service/crypto dependency). The existing architecture — DSC for
packages/registry/environment/settings, `apply.ps1` for everything requiring
crypto, service lifecycle, file-editing with managed blocks, or CLI tools with
uncertain PATH — is correct.

## Package manager preference hierarchy

When adding a new tool or capability, choose the package manager in this order:

1. **WinGet (`system.dsc.yml`)** — preferred for any package with a WinGet ID.
   Declarative, `--what-if`-capable, and centrally tracked.
2. **Scoop (`src/modules/windows/scoop-setup.ps1`)** — for portable CLI
   utilities that have no WinGet ID but exist in a Scoop bucket.  Scoop is the
   user-space fallback: it requires no admin rights and installs to
   `%USERPROFILE%\scoop\`.
3. **cargo binstall (`src/modules/windows/cargo-binstall-setup.ps1`)** — for
   Rust CLI tools not available in WinGet or Scoop.  cargo-binstall downloads
   prebuilt binaries without requiring a local Rust toolchain.
4. **bun (`src/modules/windows/bun-setup.ps1`)** — last resort for JS/npm-only
   tools absent from WinGet, Scoop, and cargo-binstall.  `bun install -g`
   places binaries in `%USERPROFILE%\.bun\bin`.  Bun itself is installed via
   WinGet (`Oven-sh.Bun` in `system.dsc.yml`).

The equivalent hierarchy on POSIX hosts is:
`nixpkgs > cargo binstall > bun`.

Document any departure from this order with a short WHY comment explaining why
a higher tier was unavailable for the specific package.

## Scoop as user-space package manager

### Role and scope

Scoop is the user-space package manager for portable CLI utilities that have no
WinGet package ID. It installs to `%USERPROFILE%\scoop\` without requiring
admin rights. Use Scoop when a tool is absent from WinGet but available in a
Scoop bucket (e.g. `cargo-binstall` from the `main` bucket).

### Declaring Scoop in system.dsc.yml

Install Scoop itself via WinGet (package ID `Scoop.Scoop`). Scoop requires
`Git.Git` for bucket management; ensure it appears in the packages list. Use
`dependsOn` to enforce ordering:

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
    - GitInstall   # the id: of the Git.Git package entry
```

### Scoop bucket and app provisioning

Do **not** use `PSDscResources/Script` for Scoop bucket or app management after
a fresh `Scoop.Scoop` install. Reason: `scoop` lives at
`~\scoop\shims\scoop.ps1` which is not on PATH in the DSC execution session
immediately after WinGet installs Scoop — the same PATH-guarantee constraint
that excludes cargo-cache.

Instead, manage Scoop buckets and apps in a dedicated module
`src/modules/windows/scoop-setup.ps1` dot-sourced and called by `apply.ps1`
**after** the DSC run completes, so `~\scoop\shims` is resolvable by then.

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

After Scoop installs cargo-binstall, `src/modules/windows/cargo-binstall-setup.ps1`
manages Rust CLI tools that have no WinGet or Scoop equivalent (e.g.
`cargo-cache`, `pay-respects`).  It maintains a desired-state list and a
manifest at `~\.config\nucleus\cargo-binstall-packages.json`; on each apply it
installs additions via `cargo binstall --no-confirm` and removes deletions via
`cargo uninstall`.

**PATH note**: DSC runs in a fresh session where `~\.cargo\bin` is not on PATH.
The setup module prepends `~\.cargo\bin` internally before any `cargo uninstall`
call.  When invoking cargo-binstall from `apply.ps1` (after the DSC run), Scoop
shims at `~\scoop\shims` are already resolvable.

## Cross-host equivalence checks

- Before adding a Windows package, check whether the capability should be
  mirrored in `src/modules/core.nix` for macOS/NixOS parity.
- Before adding a new cross-host CLI tool in `core.nix`, check whether Windows
  should receive the same capability through `system.dsc.yml`.
- Prefer implementing parity in the same change when practical; if not,
  document the platform-specific rationale.
- Follow `.agents/instructions/cross-host-feature-parity.instructions.md`
  for parity-first scope decisions.

## Imperative fallback safety (Windows modules)

When a capability cannot be represented in WinGet DSC and must be implemented
in `src/modules/windows/*.ps1` + `apply.ps1`, enforce all of the following:

- **Managed-scope only**: modify only declaratively managed files/blocks/keys.
  Do not overwrite or delete unrelated user content.
- **Bounded edits**: use explicit markers (or equivalent precise selectors) for
  file edits so cleanup can remove only managed content.
- **Fail-fast on unsafe state**: if a required precondition is ambiguous or a
  target looks externally managed, stop with an error instead of guessing.
- **Idempotent configuration**: re-running apply must converge to the same
  state without duplicating blocks or repeatedly mutating equivalent values.
- **Idempotent deconfiguration**: disabling a feature must safely remove only
  managed state and be no-op when already absent.
- **Explicit toggle**: every imperative parity feature must expose an enable/
  disable toggle in `src/hosts/windows/apply.ps1` and wire cleanup when false.

## Validation

- Test the manifest dry-run on the target machine with:
  ```powershell
  winget configure --what-if .\src\hosts\windows\system.dsc.yml
  winget configure --what-if .\src\hosts\windows\user.dsc.yml
  ```
- Full application requires an elevated PowerShell session and
  `--accept-configuration-agreements`.
- The `scripts/bootstrap.ps1` wrapper passes both flags automatically.

## What to avoid

- Do not add duplicate entries for tools already managed by another Windows
  declarative layer. In this repository, `system.dsc.yml` is the canonical
  Windows package baseline and should be kept intentionally in parity with
  shared host policy.
- Do not hard-code version strings in `settings.id` unless pinning to a
  specific release is intentional; WinGet resolves the latest by default.
- Do not leave commented-out resources in the file; remove them or track
  intent in a separate note.

## Naming

- Avoid repository-brand prefixes (for example `nucleus*`) in new PowerShell
  function names and filenames unless the prefix is required for cross-module
  disambiguation or external integration points.  Use descriptive verb-noun
  patterns instead (e.g., `Sync-Wallpapers` instead of `Sync-NucleusWallpapers`).
