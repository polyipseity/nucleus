---
description: "Use when adding or modifying scripts, tests, or automation that depends on external tool availability. Covers the ban on silent skip-guards and the required hard-fail policy."
name: "Tool Availability Policy"
applyTo: "scripts/**, src/scripts/**, tests/**/*.sh, tests/**/*.ps1, src/hosts/Windows/modules/**/*.ps1"
---

# Tool Availability Policy

Scripts in this repository assume all required tools are installed. Silent skip-guards that exit 0 or return 0 when a tool is unavailable are banned.

## Policy

- **Do not guard tool use with silent skip.** If a script needs a tool and it is missing, the script must fail loudly — not silently skip work.
- **No `command -v <tool> || return 0` / `exit 0` patterns.** If a tool is mandatory for a section of work, do not silently skip that section when the tool is absent.
- **No `Test-CommandAvailable` / `Get-Command -ErrorAction SilentlyContinue` gating that exits successfully on absence.** Unconditional execution is the default; missing tools produce clear errors.

## Allowed patterns

- **Inline alternative selection.** Choosing between equivalent tools (e.g., `code` vs `code-insiders`, or `gsha256sum` vs `shasum -a 256`) is permitted, as long as at least one alternative is required to be present.
- **Pre-flight validation at script entry.** A script may check for all required tools at startup and `exit 1` with a descriptive message if any are missing. This is preferred over inline skip-guards.
- **Genuinely optional features.** If a *feature* (not a tool) is optional, the decision must be configuration-driven (e.g., section filters via `-Sections`/`SECTIONS`), not implicit tool-detection.

## Enforcement

The `nucleus-check-sh` and `nucleus-check-pwsh` validators reject scripts that contain `command -v` (or equivalent) in a skip-guard pattern. Review new dependencies against this policy before adding them.
