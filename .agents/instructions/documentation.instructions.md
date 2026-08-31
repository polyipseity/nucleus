---
description: "Use when adding or editing any infrastructure code: Nix files, PowerShell modules, WinGet DSC YAML, shell scripts, or MANUAL.md host docs. Mandates documentation standards for each file type, citation quality rules, and the WHY-not-WHAT commenting principle."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
---

# Documentation Standards

Document the **WHY, not the WHAT**: rationale, security implications, and design tradeoffs — not restatements of existing code. Use the formal documentation mechanism for each file type; fall back to `#` comments when none exists. Rationale comments use the canonical `# WHY: <reason>` form (mandatory colon, lowercase keyword); see `comment-annotations.instructions.md`.

- **No backwards compatibility**: see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility). Document the current path only.

## Provenance for non-validated external identifiers

When a setting cannot be auto-validated by tests or schemas, include an inline source citation (see Citation quality below).

## Nix files (`src/**/*.nix`)

There is no Nix-native documentation tool in use here; inline `#` comments are the documentation mechanism.

- **File header**: every `.nix` file must open with a `#` comment stating the file path relative to `src/`, a dash, and a plain-language description of the module's purpose and scope. Example: `# modules/shell.nix — Interactive shell configuration for all hosts.`
- **Non-trivial `let` bindings**: every helper function, derived value, or multi-step computation in a `let` block needs at least one `#` comment explaining what it computes and why it exists — not just naming it.
- **`system.activationScripts` and `home.activation` entries**: each entry must have a banner comment (separator line + entry name + purpose + algorithm notes) explaining what the script does, what invariant it maintains, and any side effects. See `platforms/macOS/modules/default.nix` for the established pattern.
- **Module options (`lib.mkOption`)**: the `description` field is the formal documentation mechanism for Nix module options and is mandatory on every `mkOption` call. The description must explain what the option controls and what effect different values have, not merely restate the type.
- **Non-obvious inline code**: `builtins.*` calls, `lib.*` expressions, and config block patterns that are not immediately self-evident to a reader unfamiliar with Nix or this codebase must have a `#` comment explaining the purpose.
- **Document the WHY**: prefer comments that explain the rationale, security implication, or design tradeoff behind a setting (e.g. why a PAM service name was chosen, why an option combination closes a specific attack surface) over comments that merely describe what the option does.

## PowerShell files (`src/**/*.ps1`)

Comment-based help (`<# … #>`) is the formal documentation mechanism for PowerShell and is required on every function and entry-point script.

- **Script-level help**: every `.ps1` script that is invoked as an entry point must open with a `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` block placed directly before the `[CmdletBinding()]` or `param(…)` declaration.
- **Function-level help**: every `function Verb-Noun { … }` must have its own `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .OUTPUTS … .EXAMPLE … #>` block. Required sections: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per parameter), `.EXAMPLE`. Add `.OUTPUTS` whenever the function returns a value.
- **Inline logic comments**: non-trivial logic blocks, exit-code checks, and PowerShell idioms that are not immediately obvious must have an inline `#` comment explaining what the block does and, where relevant, why this approach was chosen over alternatives.
- **Document the WHY**: record the rationale behind security-sensitive patterns (e.g. "env var cleared in `finally` so it is never left in the environment on failure") and any non-obvious error-handling or recovery behaviour.

## WinGet DSC YAML (`src/hosts/Windows/**/*.yml`)

The `directives.description:` field on each resource entry is the formal documentation mechanism for WinGet DSC configurations.

- **Mandatory**: every resource entry must include a non-empty `directives.description:` value.
- **WHY not WHAT**: the description must state the reason the resource exists and its practical effect, not merely restate the resource type or key names. For example, "Enable long path support so Nix store paths and deep Git trees do not hit the 260-character Windows limit" is better than "Enable long path support in the registry."
- **Setting rationale**: when a resource sets a non-obvious registry value, environment variable, or system flag, the description must explain what enabling or disabling the setting changes in practice.
- **Dependency rationale**: if a resource uses `dependsOn:`, the description should note why the ordering constraint exists.

## Shell scripts (`scripts/**`, `src/scripts/**`)

There is no formal documentation tool for POSIX sh or Bash; `#` comments are the documentation mechanism.

- **File header**: every shell script must begin (after the shebang) with a `#` comment block that states: (1) what the script does, (2) the commands or arguments it accepts, (3) environment variables it reads, and (4) exit conditions or prerequisites.
- **Function-level comments**: every named function definition must have a `#` comment block immediately before it that states: what it does, its arguments (`# Args: $1 — …`), what it outputs or side-effects, and any noteworthy preconditions. See `scripts/bootstrap.sh` for the established pattern.
- **Non-trivial inline logic**: `case` branches, conditional chains, and environment variable reads that are not self-explanatory must have an inline `#` comment explaining the branch condition and its effect.
- **Document the WHY**: state why a particular tool or flag was chosen (e.g. "`set -a` exports all variables so child processes inherit version pins") and document any behaviour that a future reader might otherwise change incorrectly.

## Host MANUAL.md (`src/hosts/**/MANUAL.md`)

MANUAL.md files are concise post-apply checklists. They must contain only steps that cannot be safely automated.

- **Ongoing operations only — never one-off migrations.** `MANUAL.md` is not a migration runbook. One-off path moves and cleanup must be executed on affected hosts before the breaking commit lands; do not add deferred migration sections or checklists to `MANUAL.md` (see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility)).
- Keep formatting minimal: title plus short bullet lists. Prefer direct actions with concrete names in backticks.
- Include a `command shortcuts` section (complete set, names starting with `-` like `-g`, `-ga`) and a separate `nucleus commands` section.
- Group permission-grant steps by category (e.g. Accessibility, Screen Recording); each permission appears once with all apps that need it.
- Do not duplicate behavior that `apply` already guarantees. Remove steps when they become automatable.
- Point to setup commands (e.g. `nucleus-cloud setup`) instead of expanding internal details.

## UI Label Naming Convention

All user-facing UI labels — right-click context menu entries, dock/folder/script labels, button text, and any other visible text — must use sentence case (capitalize only the first word and proper nouns).

This applies across all hosts: macOS `.app` bundles (`NSMenuItem`), NixOS file manager entries (Nautilus scripts, Dolphin `Name=`), and Windows Registry context menu entries (`valueData`).

Exception: system-internal identifiers like `CFBundleIdentifier`, filenames on disk that differ from display names, and AppleScript source code may use whatever case the platform requires.

## Citation quality

When citing external sources (APIs, documentation, vendor settings, support articles), keep URLs and content correct to prevent drift.

### Source preference (priority order)

For claims about behavior, APIs, or configuration settings:

1. **Developer/API documentation first**
   - Apple: `developer.apple.com/documentation/*`
   - Microsoft: `learn.microsoft.com/en-us/windows/*` or `learn.microsoft.com/en-us/dotnet/*`
   - Official language/framework reference
   - IETF RFCs for standards

2. **User-oriented help only when developer docs don't exist**
   - Apple: `support.apple.com/en-us/guide/*` (add explicit locale prefix)
   - Microsoft: KB articles
   - Vendor release notes or blogs
   - If you must use a support page where a developer doc exists, add a `# WHY:` comment explaining why the support page is the only available source

3. **Avoid**
   - Mirrors, archived copies, or third-party rewrites (use canonical source)
   - Forum posts, Reddit, Stack Overflow (document internal consensus via comments, not external link)
   - Expired links or pages under redirect chains

### URL standardization

**Apple support URLs must include explicit US English locale:**

- ✅ `https://support.apple.com/en-us/guide/mac-help/...`
- ✅ `https://support.apple.com/en-us/HT123456`
- ❌ `https://support.apple.com/guide/mac-help/...` (no locale prefix; redirects based on browser locale)
- ❌ `https://support.apple.com/HT123456` (no locale prefix)

**Preferred URL form:**

- Use canonical, stable URLs without query parameters (e.g., `?search=...`)
- Avoid short URLs or redirects if a canonical form exists
- Include article/page ID (HT numbers, doc IDs) when possible for long-term stability

### Deprecation hygiene

When citing APIs or settings:

1. **Do not cite deprecated APIs as current behavior**
   - Carbon framework (macOS) → replace with modern equivalent (InputMethodKit, AppKit, SwiftUI)
   - CoreGraphics (legacy) → consider modern Cocoa APIs
   - When in doubt, check Apple's official deprecation notices

2. **If a deprecated API must be documented** (for historical context):
   - Mark it as deprecated in the comment
   - Cite the deprecation notice
   - Cite the modern replacement API in the same block
   - Example:

     ```nix
     # Old approach (deprecated): use Carbon Text Services Manager
     # Modern approach: use InputMethodKit
     # Source: https://developer.apple.com/documentation/inputmethodkit
     ```

### Citation style in code/config

Keep citations adjacent to the claim they support:

```nix
# Good: Source immediately follows the setting claim
# Prevent .DS_Store files on network and removable volumes.
# Source: https://support.apple.com/en-us/HT208209
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true;
};

# Less good: Source buried far from the code
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true; # See https://...
};

# Avoid: No source at all, or source in wrong place
# Source: https://...
# Many lines later...
"com.apple.foo" = { ... };
```

For multi-line settings, put the source at the top of the comment block:

```nix
# Software Update: check, download, and install automatically.
# Source: https://support.apple.com/en-us/guide/deployment/manage-software-updates-depafd2fad80/web
"com.apple.SoftwareUpdate" = {
  AutomaticCheckEnabled = true;
  AutomaticDownload = true;
  CriticalUpdateInstall = true;
};
```
