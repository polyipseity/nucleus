---
description: "Use when adding or editing files under scripts/, src/scripts/, or src/hosts/windows/modules/. Covers script placement, newline policy, cross-platform behavior, runtime detection, and permission expectations."
name: "Scripts and Executable Permissions"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1"
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

## PowerShell Module Script Naming (Windows)

Every PowerShell file under `src/hosts/windows/modules/` that exports exactly one
function must follow a strict naming convention: the kebab-case filename must
convert to the function's PascalCase name.

**Conversion rule**: split the filename (without `.ps1`) by hyphens, then
PascalCase each part and concatenate.

- Examples:
  - `sync-wallpaper.ps1` → `Sync-Wallpaper`
  - `initialize-devdirectory.ps1` → `Initialize-DevDirectory`
  - `invoke-cargobinstallsetup.ps1` → `Invoke-CargoBinstallSetup`
  - `convertfrom-sshed25519publickeytoagepubkey.ps1` →
    `ConvertFrom-SshEd25519PublicKeyToAgePubKey`

**Why**: this makes the module discoverable by reading filenames and helps
maintainers quickly identify which function a script exports without opening
the file. Violations indicate the filename is either misleading or the function
name is not aligned with the intended task.

If a PowerShell file exports multiple functions or none, place it only in
`src/hosts/windows/modules/` as a utility module and prefix its name to indicate
utility scope (e.g. `load-userregistry.ps1` for a multi-function module).

## Line endings and permissions

- Respect both `.editorconfig` and `.gitattributes`:
  - `*.sh` uses LF
  - `*.ps1` uses CRLF
  - `*.bat` uses CRLF
  - additional script types should get explicit policy before widespread use
- Every `.sh`, `.ps1`, and `.bat` script file anywhere in the repository must
  have its executable bit tracked in Git, regardless of location (`scripts/`,
  `src/scripts/`, `src/hosts/windows/`, `src/hosts/windows/modules/`, or elsewhere).
  This applies to Windows scripts too — Git stores the executable bit
  independent of CRLF line endings, and many CI environments and tooling
  wrappers check the mode before invoking scripts. Set it with
  `git update-index --chmod=+x <path>` when adding or renaming any script.
  Verify the stored mode with `git ls-files --stage <path>` (mode `100755` is
  correct; `100644` is not). Non-script data files such as
  `bootstrap-versions.env`, `.yml`, `.json`, and `.nix` files must remain
  `100644`.
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

## Explicit Parameter Passing (PowerShell)

**All PowerShell functions must enforce caller awareness through explicit parameters.**

- **Mandatory behavioral parameters**: parameters controlling state changes
  (`Enabled`, `Users`, `Activated`, etc.) must be `[Parameter(Mandatory)]`.
  Do not default to `$true` or assume the current user.
- **No path auto-derivation**: never auto-derive `RepoRoot`, `ModuleDir`,
  `ConfigDir`, or other paths from `$PSScriptRoot`. Callers must pass them
  explicitly so they are aware of which paths will be modified.
- **Explicit user context always**: functions touching user profiles or home
  directories must have explicit `-Username` or `-Users` parameters. Never
  silently default to the current user or auto-discover users from the
  filesystem.
- **Remove backwards compatibility code**: this repository does not require
  support for deprecated parameters, conditional migration paths, or old
  configuration formats. If a feature has changed, remove the old path
  completely and document the breaking change clearly in examples and
  commit messages. Git preserves all history; archived code does not need
  to live alongside the current implementation.
- **Complete function signatures**: every function signature must show all
  mandatory parameters in its `.SYNOPSIS` and `.EXAMPLE` sections so callers
  know what they are required to pass.

## Terminology in Examples

**Use canonical usernames in all code examples and documentation:**

- **`admin`**: represents the primary/elevated user in examples. Use this for
  any context where the primary user is required or most common (e.g.
  `-PrimaryUsername 'admin'`, `-Users @('admin')`). Replaces historical
  context-specific usernames like `polyipseity`, `root`, etc.
- **`guest`**: represents any secondary or unprivileged user. Use when examples
  need to show multi-user scenarios (e.g. `-Users @('admin', 'guest')`). Replaces
  historical placeholders like `john`, `otheruser`, `someone`, etc.

This standardization makes examples portable and immediately clear about user
context without needing explanation or configuration.

## Tooling alignment

- Keep script behavior consistent with CI, `AGENTS.md`, and prompt guidance.
- If a script wraps project tooling, keep the underlying canonical commands
  discoverable in docs and config instead of hiding the real workflow.
- When script location or behavior changes, re-check `.github/workflows/ci.yml`,
  `.vscode/settings.json`, and any prompt or instruction files that reference
  it.

## health-check.sh SOPS identity resolution

`scripts/health-check.sh` calls `sops -d <file>` to verify that current machine
identities can decrypt each managed secret before activation proceeds.

sops does **not** search `/etc/sops/age/machine.txt` by default — it only
checks standard user-level locations (`SOPS_AGE_KEY_FILE` env var,
`~/Library/Application Support/sops/age/keys.txt`,
`~/.config/sops/age/keys.txt`, etc.). On provisioned machines the machine age
private key is written to `/etc/sops/age/machine.txt` by `deriveHostAgeKey`
(in `posix-sops.nix`). Without an explicit pointer, every `sops -d` call falls
through to GPG, which may not have the secret key in the keyring at
health-check time.

**Required pattern** — export `SOPS_AGE_KEY_FILE` before the sops probe loop:

```sh
# The machine age private key lives at /etc/sops/age/machine.txt (written by
# deriveHostAgeKey).  sops does not search this path by default; set
# SOPS_AGE_KEY_FILE so the machine identity is used on provisioned hosts.
# On first bootstrap before deriveHostAgeKey has run the file is absent;
# sops falls back to GPG (imported as a bootstrap prerequisite).
_sch_machine_key="/etc/sops/age/machine.txt"
if [ -f "$_sch_machine_key" ]; then
  SOPS_AGE_KEY_FILE="$_sch_machine_key"
  export SOPS_AGE_KEY_FILE
fi
```

Without this, the health-check will fail on provisioned machines whenever the
GPG private key is not in the running keyring (common in headless sessions or
after a fresh login).

## PowerShell Linting

Always suppress the `PSUseBOMForUnicodeEncodedFile` lint rule when:

- Running the PowerShell analyzer (`Invoke-ScriptAnalyzer`)
- Configuring suppressions in `scripts/check-pwsh.ps1`

This rule should be consistently suppressed across the repository's PowerShell
scripts since UTF-8 without BOM is the standard encoding for the codebase
and enforced by `.editorconfig` and other repository policies.
