---
description: "Use when authoring or editing code comment annotations in this repo. Covers canonical grammar, the four-category taxonomy, the machine-parsing invariant, check-id registry, and enforcement greps."
name: "Comment Annotations"
applyTo: "scripts/**, src/**, tests/**"
---

# Comment annotations

Canonical policy for comment-based annotations across all platforms and file types (sh, zsh, ps1, nix, dsc.yml, hcl, md).

## Machine-parsing invariant

**Category 1 and 2 families MUST be machine-parsed; Category 3 and 4 may NOT be.** Each family's registry lists its live consumer (check step or tool). Non-machine-parsed annotations belong in Category 4 or must gain a parser.

## Canonical grammar

`# <prefix>: <reason>` (plain) or `# <prefix>: <subject> -- <reason>` (subject).

| Prefix | Category | Plain | Subject |
| --- | --- | --- | --- |
| `check-suppress:<id>` | 1 | `# check-suppress:suppression_doc: grep no-match exit 1 is expected here` | `# check-suppress:embedded-content: exception 3 (C# interop, <=25 lines) -- P/Invoke classes stay inline` |
| `ref` | 4 | `# ref: allow-and-deny-lists.instructions.md#A1` | `# ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator contains pip/npm patterns` |
| `WHY` | 4 | `# WHY: <reason>` — colon mandatory | — |
| `TODO` | 4 | `# TODO: <text>` — colon mandatory | — |

Rules:

- `--` is the ONLY separator; em dash `—` never in markers (allowed in prose).
- `reason:` keyword eliminated except shellcheck inner `# reason:` (Category 2).
- `method N` lowercase; `Method` not a proper noun.
- Trailing annotation swallows everything after it — never put code after `# check-suppress:` on the same line.

## Unified taxonomy

### Category 1 — Tool-enforced → `# check-suppress:<check id>: ...` (ALL machine-parsed)

| Family | Sites | Check id | Consumer |
| --- | --- | --- | --- |
| `# Inline by embedded-content policy exception N (name).` | 10+1 | `embedded-content` | step 14 `repository-policy` `.ps1` |
| `# Method N (name) -- <why>` (legacy) | 68→71 | `config-method` | step 14 `.ps1` + `.sh` twin |
| `# check-suppress:SuppressMessageAttribute: <rule> -- <just>` | 33 | `SuppressMessageAttribute` | step 12 `Get-UndocSuppViolation` |
| `# check-suppress:suppression_doc: <just>` | 623 | `suppression_doc` | step 12 regex `# check-suppress:$CheckId[\s:]` |
| `# check-suppress:packer_validate: ...` | 1 | `packer_validate` | `scripts/check.ps1` + `.sh` |
| `\|\| true` / `$null =` / `[void]` | 11 sh + 92 ps1 | `suppression_doc` | step 12 (`tests/` exempt) |

**Suppression semantics:** `|| true`, `$null =`, `[void]` are suppression patterns, not rationale markers — justify with `# check-suppress:suppression_doc:`, never `# WHY:`.

**Counting sites:** CODE-ONLY. `git grep -h 'check-suppress:<id>:' -- '*.ps1' '*.sh' '*.nix' '*.zsh' | wc -l`. Literal `$` patterns must be single-quoted.

### Category 2 — Tool-fixed (ALL machine-parsed)

| Family | Consumer |
| --- | --- |
| `# shellcheck disable=SCxxxx` / `# shellcheck source=` (+ inner `# reason:`) | shellcheck |
| `[SuppressMessageAttribute('Rule','')]` | PSScriptAnalyzer |
| `# >>> begin nucleus-managed: <subject> >>>` / `# <<< end nucleus-managed: <subject> <<<` | the managing script |
| `<!-- markdownlint-disable ... -->` | markdownlint (config-only) |

**Sentinel convention:** `>>>`/`<<<` delimit nucleus-managed blocks. Reserved for machine-managed regions.

### Category 3 — Structural markers (NOT machine-parsed)

Dividers (`# --- section ---`), DSC headers (`# WinGet DSC v3 -`, `# Sorting policy:`, `# Elevation policy:`). Documented only.

### Category 4 — Human-readable (NOT machine-parsed)

| Family | Sites | Form |
| --- | --- | --- |
| `# ref:` | 54 | `# ref: <target> -- <just>` (no `reason:`; em dash → `--`) |
| DSC reference headers (ex-`# Source:` / `# Cross-reference:` / `# See:`) | 0 | migrated → `# ref:` |
| `# WHY:` | 171 (0 no-colon) | `# WHY: <reason>` — colon mandatory |
| `# TODO:` | 0 tracked | `# TODO: <text>` — colon mandatory |

## Check-id registry

| Check id | Family | Consumer |
| --- | --- | --- |
| `suppression_doc` | suppression documentation | step 12 `.ps1` + `.sh` |
| `SuppressMessageAttribute` | PSSA rule-name suppression | step 12 `Get-UndocSuppViolation` |
| `packer_validate` | packer checksum annotations | `scripts/check.ps1` + `.sh` |
| `embedded-content` | embedded-content exceptions | step 14 `repository-policy` `.ps1` |
| `config-method` | config method annotations | step 14 `repository-policy` `.ps1` + `.sh` |

New tool-enforced markers MUST register a check id AND machine consumer before use.

## `# WHY:` usage

- `# WHY: <reason>` — colon mandatory, lowercase. Explain non-obvious decisions (WHY-not-WHAT per `documentation.instructions.md`).
- Scope: sh, zsh, ps1, nix, dsc.yml; rationale only.
- NOT for: suppressions (`|| true` → `check-suppress:suppression_doc:`), tool-enforced (`check-suppress:`), references (`ref:`), pending work (`TODO:`).

## `# ref:` usage

- `# ref: <target>` (plain) or `# ref: <target> -- <just>` (subject). Use for policy citations, dependency notes, source-of-truth pointers. No `reason:` keyword, no em dash.

## Enforcement greps (wired into check steps where noted)

| Gate | Target | Wired? |
| --- | --- | --- |
| `# WHY [^:]` = 0 | no-colon WHY | no |
| `# TODO[^:]` = 0 | no-colon TODO | no |
| `# undoc-supp:` = 0 | deprecated format | no |
| bare `Inline by embedded-content` = 0 | migrated annotations | step 14 |
| capital `# Method` = 0 | lowercase method | step 14 |
| no `—` after `# check-suppress:` | no em dash in markers | no |
| no `—` after `# ref:` | no em dash in refs | no |
| `# ref:.*reason:` = 0 | no reason in refs | no |
| `# (Source\|Cross-reference\|See):` = 0 in dsc.yml | DSC headers → `ref` | no |
| `iso_checksum = "none"` without `check-suppress:packer_validate:` | annotation required | step 1 |
| bare `\|\| true` in production = 0 | undocumented suppression | step 12 (`tests/` exempt) |
| bare `$null =` / `[void]` / `2>$null` / `-ErrorAction SilentlyContinue` = 0 | undocumented suppression | step 12 |
