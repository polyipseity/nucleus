---
description: "Use when authoring or editing code comment annotations in this repo. Covers grammar, four-category taxonomy, machine-parsing invariant, check-id registry, and enforcement greps."
name: "Comment Annotations"
applyTo: "scripts/**, src/**, tests/**"
---

# Comment annotations

Grammar for comment annotations across sh, zsh, ps1, nix, dsc.yml, hcl, md.

## Grammar

`# <prefix>: <reason>` (plain) or `# <prefix>: <subject> -- <reason>` (subject). `--` is the only separator, never an em dash. `method N` is lowercase. A trailing annotation swallows the rest of the line. `reason:` is gone except inside a shellcheck directive.

| Prefix | Cat | Plain | Subject |
| --- | --- | --- | --- |
| `check-suppress:<id>` | 1 | `# check-suppress:suppression_doc: grep no-match exit 1 is expected here` | `# check-suppress:embedded-content: exception 3 (C# interop, <=25 lines) -- P/Invoke classes stay inline` |
| `ref` | 4 | `# ref: allow-and-deny-lists.instructions.md#A12` | `# ref: allow-and-deny-lists.instructions.md#A12 -- pip/npm patterns` |
| `WHY` / `TODO` | 4 | `# WHY: <reason>` / `# TODO: <text>`, colon mandatory | not used |

Categories 1 and 2 are machine-parsed and each registry row names its consumer. Categories 3 and 4 may not be machine-parsed.

## Category 1: tool-enforced

| Family | Check id | Consumer |
| --- | --- | --- |
| `# check-suppress:embedded-content: <why>` | `embedded-content` | step 13 `.ps1` + `.sh` |
| `# check-suppress:config-method: <why>` | `config-method` | step 12 `.ps1` + `.sh` |
| `# check-suppress:SuppressMessageAttribute: <rule> -- <just>` | `SuppressMessageAttribute` | step 11 `Get-UndocSuppViolation` |
| `# check-suppress:suppression_doc: <just>` | `suppression_doc` | step 11 regex |
| `# check-suppress:packer_validate: ...` | `packer_validate` | `scripts/check.ps1` + `.sh` |
| `\|\| true` / `$null =` / `[void]` | `suppression_doc` | step 11 (`tests/` exempt) |

`|| true`, `$null =`, and `[void]` are suppression patterns, not rationale. Justify each with `# check-suppress:suppression_doc:`, never `# WHY:`. Count annotations in code only (`*.ps1`, `*.sh`, `*.nix`, `*.zsh`), not in comments.

## Category 2: tool-fixed

| Family | Consumer |
| --- | --- |
| `# shellcheck disable=SCxxxx` / `# shellcheck source=` (+ `# reason:`) | shellcheck |
| `[SuppressMessageAttribute('Rule','')]` | PSScriptAnalyzer |
| `# >>> begin nucleus-managed: <subject> >>>` / `# <<< end ... <<<` | the managing script |
| `<!-- markdownlint-disable ... -->` | markdownlint (config only) |

## Categories 3 and 4: human-readable

Cat 3 covers dividers and DSC headers. Cat 4 covers `# ref: <target> -- <just>`, `# WHY: <reason>`, and `# TODO: <text>`. In DSC YAML the forms `# Source:`, `# See:`, and `# Cross-reference:` are wrong; use `# ref:`.

`# WHY:` explains a non-obvious decision. It is not for suppressions, tool-enforced markers, references, or TODOs. `# ref:` cites policy, a dependency, or a source of truth.

A new tool-enforced marker must register its check id and machine consumer before first use. Registered ids: `suppression_doc` (step 11), `SuppressMessageAttribute` (step 11), `packer_validate` (`scripts/check.*`), `embedded-content` (step 13), `config-method` (step 12).

## Enforcement

Wired: `iso_checksum = "none"` without `packer_validate:` (step 1), and bare `|| true` / `$null =` / `[void]` / `2>$null` / `-ErrorAction SilentlyContinue` in production code (step 11, `tests/` exempt).

Not wired, so a violation only shows up in review: `# WHY` without a colon, `# TODO` without a colon, `# undoc-supp:`, a bare `Inline by embedded-content`, a capitalised `# Method`, an em dash after `# check-suppress:` or `# ref:`, `reason:` in a `# ref:`, and `# Source:`/`# See:` in dsc.yml.
