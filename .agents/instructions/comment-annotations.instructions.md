---
description: "Use when authoring or editing code comment annotations in this repo. Covers grammar, four-category taxonomy, machine-parsing invariant, check-id registry, and enforcement greps."
name: "Comment Annotations"
applyTo: "scripts/**, src/**, tests/**"
---

# Comment annotations

Policy for comment-based annotations across all platforms and file types (sh, zsh, ps1, nix, dsc.yml, hcl, md).

## Machine-parsing invariant

**Category 1-2 families MUST be machine-parsed; Category 3-4 may NOT be.** Each family's registry lists its live consumer. Non-machine-parsed annotations belong in Category 4 or must gain a parser.

## Grammar

`# <prefix>: <reason>` (plain) or `# <prefix>: <subject> -- <reason>` (subject).

| Prefix | Cat | Plain | Subject |
| --- | --- | --- | --- |
| `check-suppress:<id>` | 1 | `# check-suppress:suppression_doc: grep no-match exit 1 is expected here` | `# check-suppress:embedded-content: exception 3 (C# interop, <=25 lines) -- P/Invoke classes stay inline` |
| `ref` | 4 | `# ref: allow-and-deny-lists.instructions.md#A1` | `# ref: allow-and-deny-lists.instructions.md#A1 -- pip/npm patterns in comments` |
| `WHY` | 4 | `# WHY: <reason>` — colon mandatory | — |
| `TODO` | 4 | `# TODO: <text>` — colon mandatory | — |

Rules: `--` only separator (never em dash in markers). `reason:` eliminated except shellcheck inner `# reason:` (Cat 2). `method N` lowercase. Trailing annotation swallows rest of line — no code after `# check-suppress:` on same line.

## Category 1 — Tool-enforced → `# check-suppress:<check id>: ...` (ALL machine-parsed)

| Family | Sites | Check id | Consumer |
| --- | --- | --- | --- |
| `# Inline by embedded-content policy exception N (name).` | 10+1 | `embedded-content` | step 14 `repository-policy` `.ps1` |
| `# Method N (name) -- <why>` (legacy) | 68→71 | `config-method` | step 14 `.ps1` + `.sh` |
| `# check-suppress:SuppressMessageAttribute: <rule> -- <just>` | 33 | `SuppressMessageAttribute` | step 12 `Get-UndocSuppViolation` |
| `# check-suppress:suppression_doc: <just>` | 623 | `suppression_doc` | step 12 regex |
| `# check-suppress:packer_validate: ...` | 1 | `packer_validate` | `scripts/check.ps1` + `.sh` |
| `\|\| true` / `$null =` / `[void]` | 11+92 | `suppression_doc` | step 12 (`tests/` exempt) |

**Suppression semantics:** `|| true`, `$null =`, `[void]` are suppression patterns, not rationale. Justify with `# check-suppress:suppression_doc:`, never `# WHY:`.

**Counting:** CODE-ONLY. `git grep -h 'check-suppress:<id>:' -- '*.ps1' '*.sh' '*.nix' '*.zsh' | wc -l`. Literal `$` patterns single-quoted.

## Category 2 — Tool-fixed (ALL machine-parsed)

| Family | Consumer |
| --- | --- |
| `# shellcheck disable=SCxxxx` / `# shellcheck source=` (+ `# reason:`) | shellcheck |
| `[SuppressMessageAttribute('Rule','')]` | PSScriptAnalyzer |
| `# >>> begin nucleus-managed: <subject> >>>` / `# <<< end nucleus-managed: <subject> <<<` | the managing script |
| `<!-- markdownlint-disable ... -->` | markdownlint (config-only) |

Sentinels: `>>>`/`<<<` delimit nucleus-managed blocks.

## Category 3 — Structural markers (NOT machine-parsed)

Dividers, DSC headers. Documented only.

## Category 4 — Human-readable (NOT machine-parsed)

| Family | Sites | Form |
| --- | --- | --- |
| `# ref:` | 54 | `# ref: <target> -- <just>` |
| DSC reference headers (ex-`# Source:` / `# Cross-reference:` / `# See:`) | 0 | migrated → `# ref:` |
| `# WHY:` | 171 | `# WHY: <reason>` — colon mandatory |
| `# TODO:` | 0 | `# TODO: <text>` — colon mandatory |

## Check-id registry

| Check id | Family | Consumer |
| --- | --- | --- |
| `suppression_doc` | suppression documentation | step 12 `.ps1` + `.sh` |
| `SuppressMessageAttribute` | PSSA rule-name suppression | step 12 `Get-UndocSuppViolation` |
| `packer_validate` | packer checksum annotations | `scripts/check.ps1` + `.sh` |
| `embedded-content` | embedded-content exceptions | step 14 `repository-policy` `.ps1` |
| `config-method` | config method annotations | step 14 `repository-policy` `.ps1` + `.sh` |

New tool-enforced markers MUST register check id + machine consumer before use.

## `# WHY:` usage

`# WHY: <reason>` — colon mandatory. Explain non-obvious decisions (WHY-not-WHAT per `documentation.instructions.md`). Scope: sh, zsh, ps1, nix, dsc.yml. NOT for suppressions, tool-enforced, references, or TODOs.

## `# ref:` usage

`# ref: <target>` (plain) or `# ref: <target> -- <just>` (subject). Policy citations, dependency notes, source-of-truth pointers. No `reason:` keyword, no em dash.

## Enforcement greps (wired into check steps where noted)

| Gate | Target | Wired? |
| --- | --- | --- |
| `# WHY [^:]` = 0 | no-colon WHY | no |
| `# TODO[^:]` = 0 | no-colon TODO | no |
| `# undoc-supp:` = 0 | deprecated format | no |
| bare `Inline by embedded-content` = 0 | migrated | step 14 |
| capital `# Method` = 0 | lowercase method | step 14 |
| no `—` after `# check-suppress:` | no em dash in markers | no |
| no `—` after `# ref:` | no em dash in refs | no |
| `# ref:.*reason:` = 0 | no reason in refs | no |
| `# (Source\|Cross-reference\|See):` = 0 in dsc.yml | DSC headers → `ref` | no |
| `iso_checksum = "none"` without `check-suppress:packer_validate:` | required | step 1 |
| bare `\|\| true` in production = 0 | undocumented suppression | step 12 (`tests/` exempt) |
| bare `$null =` / `[void]` / `2>$null` / `-ErrorAction SilentlyContinue` = 0 | undocumented suppression | step 12 |
