---
description: "Use when adding or editing infrastructure code: Nix files, PowerShell modules, WinGet DSC YAML, shell scripts, or MANUAL.md host docs. Mandates documentation standards per file type, citation quality, and WHY-not-WHAT commenting."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
---

# Documentation standards

Document the **WHY, not the WHAT** — rationale, security implications, design tradeoffs — not restatements of existing code. Use the formal documentation mechanism for each file type; fall back to `#` comments otherwise. Rationale comments use `# WHY: <reason>` (mandatory colon, lowercase keyword); see `comment-annotations.instructions.md`.

No backwards compatibility (see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility)): document the current path only.

When a setting cannot be auto-validated by tests or schemas, include an inline source citation (see Citation quality below).

## Nix files (`src/**/*.nix`)

Inline `#` comments are the documentation mechanism.

- **File header**: every `.nix` file opens with a `#` comment: file path relative to `src/`, a dash, and a plain-language purpose. Example: `# modules/shell.nix — Interactive shell configuration for all hosts.`
- **Non-trivial `let` bindings**: every helper function, derived value, or multi-step computation in a `let` block needs a `#` comment explaining what it computes and why.
- **`system.activationScripts` and `home.activation` entries**: each entry must have a banner comment (separator line + entry name + purpose + algorithm notes) explaining what the script does, what invariant it maintains, and any side effects. See `platforms/macOS/modules/default.nix` for the pattern.
- **`lib.mkOption` calls**: the `description` field is mandatory on every `mkOption` call. It must explain what the option controls and what effect different values have, not restate the type.
- **Non-obvious inline code**: `builtins.*` calls, `lib.*` expressions, and config block patterns not immediately clear to a reader unfamiliar with Nix must have a `#` comment explaining the purpose.
- **Document the WHY**: explain the rationale, security implication, or design tradeoff behind a setting (why a PAM service name was chosen, why an option combination closes a specific attack surface) rather than describing what the option does.

## PowerShell files (`src/**/*.ps1`)

Comment-based help (`<# … #>`) is the formal mechanism, required on every function and entry-point script.

- **Script-level help**: every entry-point `.ps1` opens with a `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` block before `[CmdletBinding()]` or `param(…)`.
- **Function-level help**: every `function Verb-Noun { … }` gets its own `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .OUTPUTS … .EXAMPLE … #>` block. Required: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per parameter), `.EXAMPLE`. Add `.OUTPUTS` when the function returns a value.
- **Inline logic comments**: non-trivial logic blocks, exit-code checks, and PowerShell idioms that are not immediately obvious need an inline `#` comment explaining what the block does and why this approach was chosen.
- **Document the WHY**: record rationale behind security-sensitive patterns (e.g. "env var cleared in `finally` so it is never left in the environment on failure") and non-obvious error-handling or recovery behaviour.

## WinGet DSC YAML (`src/hosts/Windows/**/*.yml`)

`directives.description:` on each resource entry is the formal documentation mechanism.

- Mandatory: every resource entry must include a non-empty `directives.description:` value.
- **WHY not WHAT**: state the reason the resource exists and its practical effect, not restate the resource type or key names. "Enable long path support so Nix store paths and deep Git trees do not hit the 260-character Windows limit" is better than "Enable long path support in the registry."
- When a resource sets a non-obvious value, the description must explain what enabling or disabling it changes in practice.
- If a resource uses `dependsOn:`, the description should note why the ordering constraint exists.

## Shell scripts (`scripts/**`, `src/scripts/**`)

`#` comments are the documentation mechanism.

- **File header**: every shell script begins (after the shebang) with a `#` comment block stating: (1) what the script does, (2) accepted commands/arguments, (3) environment variables read, and (4) exit conditions or prerequisites.
- **Function-level comments**: every named function gets a `#` comment block immediately before it: what it does, arguments (`# Args: $1 — …`), outputs or side-effects, and preconditions. See `scripts/bootstrap.sh` for the pattern.
- **Non-trivial inline logic**: `case` branches, conditional chains, and environment variable reads that are not self-explanatory need an inline `#` comment.
- **Document the WHY**: state why a tool or flag was chosen (e.g. "`set -a` exports all variables so child processes inherit version pins") and document any behaviour a future reader might change incorrectly.

## Host MANUAL.md (`src/hosts/**/MANUAL.md`)

Concise post-apply checklists containing only steps that cannot be safely automated.

- **Ongoing operations only — never one-off migrations.** Execute path moves and cleanup before the breaking commit lands; do not add deferred migration sections (see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility)).
- Keep formatting minimal: title plus short bullet lists. Use direct actions with concrete names in backticks.
- Include a `command shortcuts` section (complete set, names starting with `-` like `-g`, `-ga`) and a separate `nucleus commands` section.
- Group permission-grant steps by category (e.g. Accessibility, Screen Recording); each permission appears once with all apps that need it.
- Do not duplicate behavior that `apply` already guarantees. Remove steps when they become automatable.
- Point to setup commands (e.g. `nucleus-cloud setup`) instead of expanding internal details.

## UI label naming convention

All user-facing UI labels (right-click context menu entries, dock/folder/script labels, button text, and other visible text) use sentence case (capitalize only the first word and proper nouns). This applies across all hosts: macOS `.app` bundles (`NSMenuItem`), NixOS file manager entries (Nautilus scripts, Dolphin `Name=`), and Windows Registry context menu entries (`valueData`).

Exception: system-internal identifiers (`CFBundleIdentifier`), filenames on disk that differ from display names, and AppleScript source code may use whatever case the platform requires.

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
   - Apple: `support.apple.com/en-us/guide/*` (explicit locale prefix)
   - Microsoft: KB articles
   - Vendor release notes or blogs
   - If you must use a support page where a developer doc exists, add a `# WHY:` comment explaining why.

3. **Avoid**
   - Mirrors, archived copies, or third-party rewrites (use canonical source)
   - Forum posts, Reddit, Stack Overflow (document internal consensus via comments, not external links)
   - Expired links or redirect chains

### URL standardization

**Apple support URLs must include explicit US English locale:**

- ✅ `https://support.apple.com/en-us/guide/mac-help/...`
- ✅ `https://support.apple.com/en-us/HT123456`
- ❌ `https://support.apple.com/guide/mac-help/...` (no locale prefix; redirects based on browser locale)
- ❌ `https://support.apple.com/HT123456` (no locale prefix)

Use canonical, stable URLs without query parameters. Avoid short URLs or redirects when a canonical form exists. Include article/page IDs (HT numbers, doc IDs) for long-term stability.

### Deprecation hygiene

1. **Do not cite deprecated APIs as current behavior.** Carbon framework (macOS) → replace with InputMethodKit, AppKit, SwiftUI. CoreGraphics (legacy) → consider modern Cocoa APIs. When in doubt, check Apple's official deprecation notices.
2. **If a deprecated API must be documented** (historical context): mark it as deprecated, cite the deprecation notice, and cite the modern replacement in the same block:

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
