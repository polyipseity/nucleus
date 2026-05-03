---
description: "Use when authoring or editing WinGet DSC configuration files under src/hosts/windows/. Covers DSC v3 YAML structure, resource ordering, sorting, and safe authoring patterns for this repository."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/windows/**/*.yaml, src/hosts/windows/**/*.yml"
---

# WinGet DSC Authoring

## File location and purpose

- `src/hosts/windows/configuration.dsc.yaml` is the single WinGet DSC v3
  manifest for the Windows host.
- It is applied with `winget configure` (see `README.md` and
  `scripts/bootstrap.ps1` for the exact invocation).

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

Organize resources into these logical groups, in this order:

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

- Always specify `source: winget` for `Microsoft.WinGet.Client/Package`
  entries; do not omit it even if it is technically the default.
- Use the canonical WinGet package identifier (verified via `winget search`)
  rather than a display name or URL.
- For registry values, always include `valueType` (`DWord`, `String`, etc.)
  to prevent ambiguous interpretation.
- Environment variable scope must be `User` or `Machine`; prefer `User` unless
  the setting must be machine-wide.
- Use `%USERPROFILE%` rather than a hard-coded path for the user's home
  directory in `value` strings.

## Validation

- Test the manifest dry-run on the target machine with:
  ```powershell
  winget configure --what-if .\src\hosts\windows\configuration.dsc.yaml
  ```
- Full application requires an elevated PowerShell session and
  `--accept-configuration-agreements`.
- The `scripts/bootstrap.ps1` wrapper passes both flags automatically.

## What to avoid

- Do not add entries for tools also managed by Nix (e.g. `git`, `ripgrep`,
  `fd`) on the same machine; keep each layer responsible for its own packages.
- Do not hard-code version strings in `settings.id` unless pinning to a
  specific release is intentional; WinGet resolves the latest by default.
- Do not leave commented-out resources in the file; remove them or track
  intent in a separate note.
