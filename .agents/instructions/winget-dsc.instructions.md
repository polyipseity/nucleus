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

## Cross-host equivalence checks

- Before adding a Windows package, check whether the capability should be
  mirrored in `src/modules/core.nix` for macOS/NixOS parity.
- Before adding a new cross-host CLI tool in `core.nix`, check whether Windows
  should receive the same capability through `system.dsc.yml`.
- Prefer implementing parity in the same change when practical; if not,
  document the platform-specific rationale.
- Follow `.agents/instructions/cross-host-feature-parity.instructions.md`
  for parity-first scope decisions.

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
