---
description: "Use when generating or editing JSON/YAML data files from code (Nix, PowerShell, shell). Covers deterministic key/array ordering and trailing-newline policy so committed artifacts are diff-friendly."
name: "Deterministic JSON generation"
applyTo: "src/**/*.json, src/**/*.jsonc, src/**/*.yaml, src/**/*.yml, src/modules/lib/json.nix, src/platforms/Windows/modules/lib/JsonSort.ps1, scripts/config.ps1, scripts/update.ps1, src/flake.nix"
alwaysApply: true
---

# Deterministic JSON generation

Generated JSON artifacts (e.g. `winget-packages.json`, `lockfile.json`) are committed to the repo and consumed by other tooling. They MUST be byte-stable across runs so diffs show only real changes.

## Rules

1. **Object keys sorted case-sensitively.** Emit keys in ascending order by char code (`A`–`Z` < `a`–`z`). `ConvertTo-Json` (PowerShell) does NOT sort — it preserves insertion order — so do not rely on it for key ordering. Build the object with keys already in sorted order, or sort explicitly.
2. **Array elements sorted case-sensitively** when the array is a set/allow-list (e.g. WinGet id lists). Sort by char code before serialization.
3. **Single trailing newline.** End the file with exactly one `\n`. `Set-Content -NoNewline` strips the newline — append `` "`n" `` (or the platform newline) before it, or use a writer that adds it.
4. **Multi-line output.** Emit pretty-printed, 2-space-indented JSON (one key/element per line), not one-line/compact JSON. Use `toSortedJSON` (Nix) or `ConvertTo-SortedJson` (PowerShell) — both emit multi-line by default. Empty objects/arrays stay compact (`{}` / `[]`).
5. **Deterministic and diff-friendly.** No insertion-order drift, no unsorted maps, no missing/extra trailing newline, no one-line compaction.

## Exception — in-memory JSON

The multi-line rule (rule 4) applies only to JSON **written to a committed file**. In-memory JSON that is never persisted — e.g. values interpolated into a single-line shell command, in-memory attrset manifests, or pipes — is exempt and may stay one-line (e.g. `builtins.toJSON` call sites in `editors.nix`, `env-catalog.nix`, `symlinks.nix`, `secrets.nix`, `home.nix`).

## Shared utilities

- Nix: `src/modules/lib/json.nix` `toSortedJSON` — builds a multi-line, 2-space-indented, sorted-key, sorted-array JSON string with a trailing newline.
- PowerShell: `Sort-JsonObject` / `ConvertTo-SortedJson` in `src/platforms/Windows/modules/lib/` — sort keys/arrays and emit multi-line with a trailing newline.
- Prefer these over ad-hoc `builtins.toJSON` / `ConvertTo-Json` when the output is committed or compared for parity.

## Related instruction files

- `core-behavior.instructions.md` — Terminal output hygiene (redirect, never pipe).
- `workspace-guidance.instructions.md` — Inline `$schema` requirement for JSON/YAML data files.
