---
description: "Use when adding or editing files under scripts/. Covers script placement, newline policy, cross-platform behavior, runtime detection, and permission expectations."
name: "Scripts and Executable Permissions"
applyTo: "scripts/**"
---
# Scripts and Executable Permissions

## Scope and template state

- Keep repo-level helper scripts in `scripts/`; the directory may currently
  contain only `.gitkeep` until a downstream setup adds real scripts.
- Do not scatter contributor-facing or CI-facing automation across random
  folders when `scripts/` is the intended home.

## Placement and naming

- Name scripts for the task they perform (`bootstrap`, `check`, `release`,
  etc.) and keep each script narrowly focused.
- Choose the extension that matches the intended shell or runtime instead of
  relying on ambiguous launcher behavior.
- If a script becomes application code rather than repo automation, move it
  into the appropriate source tree instead of leaving it in `scripts/`.
- Detect a script's runtime from its extension, shebang, adjacent config files,
  and the commands it invokes before adding stack-specific script guidance.
- If a new runtime appears in `scripts/`, add or update a focused instruction
  file for that runtime only after confirming it is part of the repo's real
  setup.

## Line endings and permissions

- Respect both `.editorconfig` and `.gitattributes`:
  - `*.sh` uses LF
  - `*.ps1` uses CRLF
  - `*.bat` uses CRLF
  - additional script types should get explicit policy before widespread use
- On non-Windows platforms, shell scripts intended for direct execution should
  have executable bits tracked correctly in Git.
- If you add a new script extension or change placement conventions, update the
  related config and any tests in the same change.

## Portability and safety

- Keep scripts non-interactive by default unless interactivity is the explicit
  purpose of the script.
- Prefer explicit error handling, predictable exit codes, and idempotent
  operations where possible.
- Do not assume Bash-only features in `.sh` unless you intentionally require
  Bash and document that requirement.
- For PowerShell, prefer clear cmdlet names over aliases in committed scripts.

## Tooling alignment

- Keep script behavior consistent with CI, `AGENTS.md`, and prompt guidance.
- If a script wraps project tooling, keep the underlying canonical commands
  discoverable in docs and config instead of hiding the real workflow.
- When script location or behavior changes, re-check `.github/workflows/ci.yml`,
  `.vscode/settings.json`, and any prompt or instruction files that reference
  it.
