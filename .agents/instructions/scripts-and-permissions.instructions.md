---
description: "Use when adding or editing files under scripts/. Covers script placement, newline policy, cross-platform behavior, runtime detection, and permission expectations."
name: "Scripts and Executable Permissions"
applyTo: "scripts/**"
---

# Scripts and Executable Permissions

## Scope

- Keep repo-level helper scripts in `scripts/`. Current contents: `bootstrap.sh`
  (Unix), `bootstrap.ps1` (Windows), and `bootstrap-versions.env` (version pins).
- Do not scatter contributor-facing or CI-facing automation across random
  folders when `scripts/` is the intended home.

## Cross-platform coordination

- Treat `scripts/bootstrap.sh` and `scripts/bootstrap.ps1` as paired entry
  points for the same bootstrap intent; keep capability parity as close as
  platform constraints allow.
- When adding a bootstrap dependency or behavior on one platform, evaluate and
  update the other platform in the same change when practical.
- Keep shared version pins in `scripts/bootstrap-versions.env` as the source of
  truth whenever both scripts depend on the same tool versions.
- Follow `.agents/instructions/cross-host-feature-parity.instructions.md`
  for parity-first scope decisions.

## Placement and naming

- Name scripts for the task they perform (`bootstrap`, `check`, `release`,
  etc.) and keep each script narrowly focused.
- Choose the extension that matches the intended shell or runtime instead of
  relying on ambiguous launcher behavior.
- If a script becomes application code rather than repo automation, move it
  into the appropriate source tree instead of leaving it in `scripts/`.
- Detect a script's runtime from its extension, shebang, adjacent config files,
  and the commands it invokes before adding stack-specific script guidance.
- `src/scripts/apply.sh` (the Nix apply dispatcher) lives under `src/` because
  it is embedded in the flake as `apps.apply`; it follows the same doc and
  line-ending rules as `scripts/` shell scripts.

## Line endings and permissions

- Respect both `.editorconfig` and `.gitattributes`:
  - `*.sh` uses LF
  - `*.ps1` uses CRLF
  - `*.bat` uses CRLF
  - additional script types should get explicit policy before widespread use
- Every `.sh` script in `scripts/` must have its executable bit tracked in Git.
  Set it with `git update-index --chmod=+x scripts/<name>.sh` when adding or
  renaming a shell script. Verify the stored mode with
  `git ls-files --stage scripts/` (mode `100755` is correct; `100644` is not).
- If you add a new script extension or change placement conventions, update the
  related config and any tests in the same change.

## Sorting

- Sort `case` branch labels, environment variable blocks, and any other
  unordered list-like constructs alphabetically.
- Do not sort `case` branches whose matching order is semantically significant
  (e.g. a catch-all `*` branch must remain last).

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
