---
description: "Use when authoring or editing WinGet DSC configuration files."
name: "WinGet DSC Authoring"
applyTo: "src/hosts/Windows/**/*.yml, src/hosts/Windows/**/*.json"
---

# WinGet DSC authoring

`system/*.dsc.yml` applies to every user; `user/*.dsc.yml` is per user via `dscConfigFiles` in `src/users/<username>/windows.json`. One file per subsystem; apply order comes from `apply.ps1`. Every resource needs `resource:`, `directives.description:`, and `settings:`; top level needs `configurationVersion: 0.2.0`.

Group order: packages, system settings, registry, environment, script. Sort each group case-folded by `settings.id` or `settings.valueName`/`settings.name`. Use `.yml`, `source: winget`, canonical ids from `winget search`, `valueType` on registry values, User scope for env vars, and `%USERPROFILE%` for home. `src/hosts/Windows/system/winget-packages.json` is generated and never hand-edited.

`PSDscResources/Script` requires a simple reliable `TestScript`, no native resource, reliable PATH in both scripts, and a concrete idempotency or `dependsOn` benefit. Scoop tools are handled after DSC by `Invoke-ScoopSetup`, never by a Script resource. Dry run with `winget configure --what-if`; full apply needs elevation and `--accept-configuration-agreements`. Avoid duplicates, accidental pins, and commented-out resources; names are verb-noun without `nucleus*`.

Details, path examples, and module rules: `src/users/default/agents/skills/nucleus-platform-reference/references/winget-dsc.md`.
