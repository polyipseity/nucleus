---
description: "Use when adding or modifying scripts, tests, or automation that depends on external tool availability. Covers the ban on silent skip-guards and the required hard-fail policy."
name: "Tool Availability Policy"
applyTo: "scripts/**, src/scripts/**, tests/**/*.sh, tests/**/*.ps1, src/hosts/Windows/modules/**/*.ps1"
---

# Tool Availability Policy

Scripts and tests in this repository assume all required tools are installed. Skip-guards that exit 0, return 0, or otherwise silently avoid work when a tool is unavailable are banned across all platforms and file types.

## Policy

- **Do not guard tool use with silent skip.** If a script needs a tool and it is missing, the script must fail loudly — not silently skip work.
- **No `command -v <tool> || return 0` / `exit 0` patterns.** If a tool is mandatory for a section of work, do not silently skip that section when the tool is absent.
- **No `Test-CommandAvailable` / `Get-Command -ErrorAction SilentlyContinue` gating that exits successfully on absence.** Unconditional execution is the default; missing tools produce clear errors.
- **No `Get-Module -ListAvailable` skip-guards in PowerShell.** Checking for a module and silently skipping (`Write-Warning; exit 0`, `Write-Warning; return`) is banned. Use a preflight check that throws on absence instead.
- **No `Test-Path` or `[ ! -f "$file" ]` skip-guards in tests.** If a test requires a platform-specific file that does not exist on the current platform, the test itself should be removed or replaced with a cross-platform alternative — not gated with a silent skip.

### Banned patterns (non-exhaustive)

```bash
# BASH — banned: silent skip on missing tool
if ! command -v pwsh &>/dev/null; then
  echo "skipping"  # BANNED — must hard-fail
  exit 0
fi

# BASH — banned: silent skip on missing module
if ! pwsh -c 'Get-Module -ListAvailable PSScriptAnalyzer'; then
  echo "skipping"  # BANNED — must hard-fail
  exit 0
fi

# BASH — banned: silent skip on missing file
if [ ! -f "some-platform-file" ]; then
  echo "skipping"  # BANNED — remove test or hard-fail
fi
```

```powershell
# PowerShell — banned: silent skip on missing module
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Write-Warning 'Module not found; skipping'  # BANNED — must throw
  exit 0
}

# PowerShell — banned: silent skip on missing command
if (-not (Get-Command -Name 'some-tool' -ErrorAction SilentlyContinue)) {
  Write-Warning 'Tool not found; skipping'  # BANNED — must throw
  return
}
```

### Allowed patterns

- **Inline alternative selection.** Choosing between equivalent tools (e.g., `code` vs `code-insiders`, or `gsha256sum` vs `shasum -a 256`) is permitted, as long as at least one alternative is required to be present.
- **Pre-flight validation at script entry.** A script or test may check for all required tools at startup and `exit 1` with a descriptive message if any are missing. This is the preferred pattern over inline skip-guards.
- **Genuinely optional features.** If a *feature* (not a tool) is optional, the decision must be configuration-driven (e.g., section filters via `-Sections`/`SECTIONS`), not implicit tool-detection.

## Enforcement

This policy applies to:
- **All check scripts** under `scripts/` (`.sh`, `.ps1`)
- **All test files** under `tests/` (`.sh`, `.ps1`)
- **All internal scripts** under `src/scripts/` (`.sh`)
- **All Windows module scripts** under `src/hosts/Windows/modules/` (`.ps1`)

The `nucleus-check-sh` and `nucleus-check-pwsh` validators reject scripts that contain `command -v` (or equivalent) in a skip-guard pattern. Review new dependencies against this policy before adding them. Violations in existing files must be removed when encountered during maintenance; they are not grandfathered.
