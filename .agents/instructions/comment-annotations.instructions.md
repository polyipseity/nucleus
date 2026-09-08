---
description: "Use when authoring or editing any code comment annotation in this repo: suppressions, references, rationale markers, sentinels, or structural comments. Covers canonical grammar, the four-category taxonomy, the machine-parsing invariant, the check-id registry, and enforcement greps."
name: "Comment Annotations"
applyTo: "scripts/**, src/**, tests/**"
---

# Comment annotations

Canonical policy for comment-based annotations across all platforms and file types (sh, zsh, ps1, nix, dsc.yml, hcl, md).

## Machine-parsing invariant

**Category 1 and 2 annotation families MUST be machine-parsed; Category 3 and 4 may NOT be.** This is a correctness gate: each family's registry lists its live machine consumer. An annotation that is not machine-parsed must live in Category 4 or gain a parser.

## Canonical grammar — one grammar, two forms

`# <prefix>: <reason>` (plain) or `# <prefix>: <subject> -- <reason>` (subject).

| Prefix | Category | Plain example | Subject example |
| --- | --- | --- | --- |
| `check-suppress:<check id>` | 1 | `# check-suppress:suppression_doc: grep no-match exit 1 is expected here` | `# check-suppress:embedded-content: exception 3 (C# interop, <=25 lines) -- P/Invoke classes stay inline` |
| `ref` | 4 | `# ref: allow-and-deny-lists.instructions.md#A1` | `# ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator contains pip/npm patterns; would cause false positives` |
| `WHY` | 4 | `# WHY: <reason>` — mandatory colon | — (no subject slot) |
| `TODO` | 4 | `# TODO: <text>` — mandatory colon | — |

Hard rules:

- `--` (two hyphens) is the ONLY separator; em dash `—` never appears in markers (allowed in prose).
- `reason:` keyword eliminated except shellcheck's inner `# reason:` (Category 2).
- `method N` lowercase; `Method` not a proper noun.
- `# WHY:` and `# TODO:` always carry a colon.
- A trailing annotation swallows everything after it on the line — never put code after `# check-suppress:` on the same line. Use the multi-line form with the annotation on the preceding line.

## Unified taxonomy

### Category 1 — Tool-enforced → `# check-suppress:<check id>: ...` (ALL machine-parsed)

| Family | Sites | Check id | Canonical form | Consumer |
| --- | --- | --- | --- | --- |
| `# Inline by embedded-content policy exception N (name).` | 10+1 | `embedded-content` | `# check-suppress:embedded-content: exception N (name) -- <reason>` | step 14 `repository-policy` `.ps1` |
| `# Method N (name) -- <why>` (legacy) | 68→71 | `config-method` | `# check-suppress:config-method: method N (name) -- <reason>` (lowercase) | step 14 `.ps1` + `.sh` twin |
| `# check-suppress:SuppressMessageAttribute: <rule> -- <just>` | 33 | `SuppressMessageAttribute` | `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>` | step 12 `Get-UndocSuppViolation -CheckId 'SuppressMessageAttribute'` |
| `# check-suppress:suppression_doc: <just>` | 623 | `suppression_doc` | unchanged (plain form) | step 12 regex `# check-suppress:$CheckId[\s:]` |
| `# check-suppress:packer_validate: ...` | 1 | `packer_validate` | unchanged | `scripts/check.ps1` + `scripts/check.sh` |
| `\|\| true` (shell) / `$null =` / `[void]` (ps1) | 11 sh + 92 ps1 | `suppression_doc` | annotate with `# check-suppress:suppression_doc: <reason>` | step 12 twins flag bare forms (`tests/` exempt) |

**Suppression semantics:** `|| true`, `$null =`, `[void]` are suppression patterns, not rationale markers — justify with `# check-suppress:suppression_doc:`, never `# WHY:`.

**Counting sites:** CODE-ONLY — exclude `.md` matches. `git grep -h 'check-suppress:<id>:' -- '*.ps1' '*.sh' '*.nix' '*.zsh' | wc -l`. Grep patterns with literal `$` must be single-quoted (e.g. `'\$null ='`).

### Category 2 — Tool-fixed (format dictated by tool; ALL machine-parsed)

| Family | Consumer |
| --- | --- |
| `# shellcheck disable=SCxxxx` / `# shellcheck source=` (+ inner `# reason:`) | shellcheck (via `scripts/check.sh sh`) |
| `[SuppressMessageAttribute('Rule','')]` attributes | PSScriptAnalyzer |
| `# >>> begin nucleus-managed: <subject> >>>` / `# <<< end nucleus-managed: <subject> <<<` sentinels | the managing script (e.g. `Sync-ShellProfile.ps1`) |
| `<!-- markdownlint-disable ... -->` | markdownlint (config-only; no runner wired) |

**Sentinel convention:** nucleus-managed blocks delimited by `# >>> begin nucleus-managed: <subject> >>>` and `# <<< end nucleus-managed: <subject> <<<`. `>>>`/`<<<` reserved for machine-managed regions.

### Category 3 — Structural markers (NOT machine-parsed)

Dividers (`# --- section ---`), DSC headers (`# WinGet DSC v3 -`, `# Sorting policy:`, `# Elevation policy:`). Documented only; never parsed.

### Category 4 — Human-readable annotations (NOT machine-parsed)

| Family | Sites | Form |
| --- | --- | --- |
| `# ref:` | 54 | `# ref: <target> -- <just>` (no `reason:`; em dash → `--`) |
| DSC reference headers (ex-`# Source:` / `# Cross-reference:` / `# See:`) | 0 | migrated → `# ref:` |
| `# WHY:` | 171 (0 no-colon) | `# WHY: <reason>` — mandatory colon |
| `# TODO:` | 0 tracked | `# TODO: <text>` — mandatory colon |

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

- Format: `# WHY: <reason>` — colon mandatory, lowercase keyword.
- Purpose: explain non-obvious decisions (WHY-not-WHAT per `documentation.instructions.md`).
- Scope: sh, zsh, ps1, nix, dsc.yml comments; rationale only.
- NOT for: suppressions (`|| true` → `check-suppress:suppression_doc:`), tool-enforced (`check-suppress:`), references (`ref:`), pending work (`TODO:`).

## `# ref:` usage

- Plain: `# ref: <target>` where `<target>` is a file, section, or policy id.
- Subject: `# ref: <target> -- <just>` when the reason is non-obvious.
- Use for: policy citations, dependency notes, source-of-truth pointers. No `reason:` keyword, no em dash.

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
