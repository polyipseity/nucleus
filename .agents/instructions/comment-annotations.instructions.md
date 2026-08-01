---
description: "Use when authoring or editing any code comment annotation in this repo: suppressions, references, rationale markers, sentinels, or structural comments. Covers the canonical grammar, the four-category taxonomy, the machine-parsing invariant, the check-id registry, and enforcement greps."
name: "Comment Annotations"
applyTo: "**"
---

# Comment annotations

Canonical policy for comment-based annotations across all platforms (macOS, NixOS, Windows) and all file types (sh, zsh, ps1, nix, dsc.yml, hcl, md).

## Machine-parsing invariant

**Every Category 1 and Category 2 annotation family MUST be machine-parsed; NO Category 3 or Category 4 family may be machine-parsed.** This is a correctness gate, not documentation: for each family the registry below lists its live machine consumer (check step or external tool). An annotation that is not machine-parsed must live in Category 4 (human) or gain a parser. Any marker that IS machine-parsed must be in Category 1 or 2.

## Canonical grammar — one grammar, two forms

`# <prefix>: <reason>` (plain form) or `# <prefix>: <subject> -- <reason>` (subject form).

| Prefix | Category | Plain form example | Subject form example |
| --- | --- | --- | --- |
| `check-suppress:<check id>` | 1 | `# check-suppress:suppression_doc: grep no-match exit 1 is expected here` | `# check-suppress:embedded-content: exception 3 (C# interop, <=25 lines) -- P/Invoke classes stay inline` |
| `ref` | 4 | `# ref: allow-and-deny-lists.instructions.md#A1` | `# ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator contains pip/npm patterns; would cause false positives` |
| `WHY` | 4 | `# WHY: <reason>` — mandatory colon | — (no subject slot) |
| `TODO` | 4 | `# TODO: <text>` — mandatory colon | — |

Hard rules:

- `--` (two hyphens) is the ONLY separator in annotations; the em dash `—` never appears in markers. Em dashes remain allowed in prose.
- The `reason:` keyword is eliminated everywhere except shellcheck's inner `# reason:` (tool-fixed, Category 2).
- `method N` is lowercase; `Method` is not a proper noun.
- `# WHY:` and `# TODO:` always carry a colon.

## Unified taxonomy

### Category 1 — Tool-enforced → `# check-suppress:<check id>: ...` (ALL machine-parsed)

| Family | Sites | Check id | Canonical form | Machine consumer |
| --- | --- | --- | --- | --- |
| `# Inline by embedded-content policy exception N (name).` | 10 + 1 detector | `embedded-content` | `# check-suppress:embedded-content: exception N (name) -- <reason>` | step 22 `.ps1` (regex `'check-suppress:embedded-content'`) |
| `# Method N (name) -- <why>` (legacy form) | 68 → 71 sites | `config-method` | `# check-suppress:config-method: method N (name) -- <reason>` (lowercase `method N`) | step 19 `.ps1` (regex `'# check-suppress:config-method'`); `.sh` twin has no `# Method` regex (checks `configs\.` method usage only) |
| `# check-suppress:SuppressMessageAttribute: <rule> -- <just>` / bare rule lists | 74 | `SuppressMessageAttribute` | `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>` | step 17 `Get-UndocSuppViolation -CheckId 'SuppressMessageAttribute'` |
| `# check-suppress:suppression_doc: <just>` | 394 | `suppression_doc` | unchanged (plain form) | step 17 regex `# check-suppress:$CheckId[\s:]` |
| `# check-suppress:packer_validate: ...` | 1 | `packer_validate` | unchanged form (implemented) | `scripts/check-packer.ps1` + `scripts/check-packer.sh` (read the comment; suppress the checksum warning when present; fail when `iso_checksum = "none"` lacks the annotation) |
| `|| true` (shell) / `$null =` / `[void]` (ps1) | 11 sh sites + ps1 sites | `suppression_doc` | annotate with `# check-suppress:suppression_doc: <reason>` (implemented) | step 17 `.sh` + `.ps1` twins flag bare `|| true` in production scripts (`tests/` exempt); `.ps1` also flags `$null =` / `[void]` |

**Suppression semantics:** `|| true`, `$null =`, and `[void]` are suppression patterns (they silence exit codes or discard values). They are NOT rationale markers — justify them with `# check-suppress:suppression_doc:` on the same line, never with `# WHY:`.

### Category 2 — Tool-fixed (format dictated by the tool; ALL machine-parsed)

| Family | Machine consumer |
| --- | --- |
| `# shellcheck disable=SCxxxx` / `# shellcheck source=` (+ inner `# reason:`) | shellcheck itself (via `scripts/check-sh.sh`) |
| `[SuppressMessageAttribute('Rule','')]` attributes | PSScriptAnalyzer itself |
| `# >>> begin nucleus-managed: <subject> >>>` / `# <<< end nucleus-managed: <subject> <<<` sentinels | the managing script (e.g. `Sync-ShellProfile.ps1` reads them as functional delimiters) |
| `<!-- markdownlint-disable ... -->` HTML comments | markdownlint (config at `.markdownlint.jsonc` + `.agents/.markdownlint.jsonc`; no runner wired today — config-only) |

**Sentinel convention:** a block that nucleus manages and regenerates is delimited by `# >>> begin nucleus-managed: <subject> >>>` and `# <<< end nucleus-managed: <subject> <<<`, where `<subject>` names the block content (e.g. `shell profile`). The framing expresses ownership by nucleus, not parity. `>>>`/`<<<` brackets are reserved for machine-managed regions.

### Category 3 — Structural markers (NOT machine-parsed)

Dividers (`# --- section ---`), DSC structural headers (`# WinGet DSC v3 -`, `# Sorting policy:`, `# Elevation policy:`). Documented only; never parsed.

### Category 4 — Human-readable annotations (NOT machine-parsed)

| Family | Sites | Canonical form |
| --- | --- | --- |
| `# ref:` | 54 | `# ref: <target> -- <just>` (drop `reason:`; em dash → `--`) |
| DSC reference headers (ex-`# Source:` / `# Cross-reference:` / `# See:`) | 0 | migrated → `# ref: <target> -- <just>`; gate `# (Source\|Cross-reference\|See):` in dsc.yml = 0 |
| `# WHY:` | 171 (0 no-colon) | `# WHY: <reason>` — mandatory colon |
| `# TODO:` | 0 tracked | `# TODO: <text>` — mandatory colon |

## Check-id registry

| Check id | Family | Consumer |
| --- | --- | --- |
| `suppression_doc` | generic suppression documentation | step 17 `.ps1` + `.sh` twin |
| `SuppressMessageAttribute` | PSSA rule-name suppression comments | step 17 `Get-UndocSuppViolation` |
| `packer_validate` | packer checksum annotations | `scripts/check-packer.ps1` + `scripts/check-packer.sh` |
| `embedded-content` | embedded-content policy exceptions | step 22 `.ps1` |
| `config-method` | config deployment method annotations | step 19 `.ps1` + `.sh` twin |

Rule: any new tool-enforced marker MUST register a check id AND a machine consumer in this registry before use.

## `# WHY:` usage

- Format: `# WHY: <reason>` — colon mandatory, lowercase keyword.
- Purpose: explain non-obvious human decisions (WHY-not-WHAT per `documentation.instructions.md`).
- Scope: sh, zsh, ps1, nix, dsc.yml comments; rationale only.
- NOT for: suppressions (`|| true`, `$null =`, `[void]` → `# check-suppress:suppression_doc:`), tool-enforced annotations (`check-suppress:`), references (`ref:`), pending work (`TODO:`).

## `# ref:` usage

- Plain form: `# ref: <target>` where `<target>` is a file, section, or policy id.
- Subject form: `# ref: <target> -- <just>` when the reason is non-obvious.
- Use for: policy citations, dependency notes, source-of-truth pointers. No `reason:` keyword, no em dash.

## Enforcement greps (documented; wired into check steps where noted)

| Gate | Target | Wired? |
| --- | --- | --- |
| `# WHY [^:]` = 0 | no-colon WHY | documented only |
| `# TODO[^:]` = 0 | no-colon TODO | documented only |
| bare `Inline by embedded-content` = 0 | migrated annotations | step 22 (updated regex) |
| capital `# Method` = 0 | lowercase method | step 19 (updated regex) |
| no `—` after `# check-suppress:` | no em dash in markers | documented only |
| no `—` after `# ref:` | no em dash in refs | documented only |
| `# ref:.*reason:` = 0 | no reason keyword in refs | documented only |
| `# (Source\|Cross-reference\|See):` in dsc.yml = 0 | DSC headers → `ref` | documented only |
| `iso_checksum = "none"` without `# check-suppress:packer_validate:` = 0 | packer_validate annotation required | step 3 (check-packer) |
| bare `|| true` in production scripts = 0 | undocumented suppression | step 17 (suppression audit; `tests/` exempt) |

## Related instruction files

- `shellcheck.instructions.md` — shellcheck directive format and `# reason:` rules (Category 2).
- `pwsh-lint-policy.instructions.md` — PSScriptAnalyzer suppression rules (Category 2).
- `embedded-content.instructions.md` — embedded-content exception citations (Category 1, check id `embedded-content`).
- `app-config-policy.instructions.md` — config deployment method annotations (Category 1, check id `config-method`).
- `documentation.instructions.md` — WHY-not-WHAT comment principle (Category 4).
- `allow-and-deny-lists.instructions.md` — `# ref:` citation style (Category 4).
- `maintain.instructions.md` (user-level) — suppression justification rule: `|| true` → `# check-suppress:suppression_doc:`, not `# WHY:`.
