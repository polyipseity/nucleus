---
description: "Use when adding or editing any infrastructure code: Nix files, PowerShell modules, WinGet DSC YAML, or shell scripts. Mandates documentation standards for each file type and applies the WHY-not-WHAT commenting principle."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Documentation Standards

Every piece of infrastructure code must be documented using the formal mechanism available for its file type. When no formal mechanism exists, inline `#` comments are required instead.

The guiding principle is **document the WHY, not the WHAT**: record the rationale, security implication, or design tradeoff behind a decision — not a restatement of what the code already says. Avoid obvious comments.

- **No backwards compatibility**: see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility). Document the current path only.

## Provenance for non-validated external identifiers

When a setting cannot be automatically validated by the repository's current tests or schema checks, include at least one inline source citation near the setting. See the Citation quality section below for standards.

## Nix files (`src/**/*.nix`)

There is no Nix-native documentation tool in use here; inline `#` comments are the documentation mechanism.

- **File header**: every `.nix` file must open with a `#` comment stating the file path relative to `src/`, a dash, and a plain-language description of the module's purpose and scope. Example: `# modules/shell.nix — Interactive shell configuration for all hosts.`
- **Non-trivial `let` bindings**: every helper function, derived value, or multi-step computation in a `let` block needs at least one `#` comment explaining what it computes and why it exists — not just naming it.
- **`system.activationScripts` and `home.activation` entries**: each entry must have a banner comment (separator line + entry name + purpose + algorithm notes) explaining what the script does, what invariant it maintains, and any side effects. See `modules/macos.nix` for the established pattern.
- **Module options (`lib.mkOption`)**: the `description` field is the formal documentation mechanism for Nix module options and is mandatory on every `mkOption` call. The description must explain what the option controls and what effect different values have, not merely restate the type.
- **Non-obvious inline code**: `builtins.*` calls, `lib.*` expressions, and config block patterns that are not immediately self-evident to a reader unfamiliar with Nix or this codebase must have a `#` comment explaining the purpose.
- **Document the WHY**: prefer comments that explain the rationale, security implication, or design tradeoff behind a setting (e.g. why a PAM service name was chosen, why an option combination closes a specific attack surface) over comments that merely describe what the option does.

## PowerShell files (`src/**/*.ps1`)

Comment-based help (`<# … #>`) is the formal documentation mechanism for PowerShell and is required on every function and entry-point script.

- **Script-level help**: every `.ps1` script that is invoked as an entry point must open with a `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` block placed directly before the `[CmdletBinding()]` or `param(…)` declaration.
- **Function-level help**: every `function Verb-Noun { … }` must have its own `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .OUTPUTS … .EXAMPLE … #>` block. Required sections: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per parameter), `.EXAMPLE`. Add `.OUTPUTS` whenever the function returns a value.
- **Inline logic comments**: non-trivial logic blocks, exit-code checks, and PowerShell idioms that are not immediately obvious must have an inline `#` comment explaining what the block does and, where relevant, why this approach was chosen over alternatives.
- **Document the WHY**: record the rationale behind security-sensitive patterns (e.g. "env var cleared in `finally` so it is never left in the environment on failure") and any non-obvious fallback behaviour or error handling choices.


## WinGet DSC YAML (`src/hosts/Windows/**/*.yml`)

The `directives.description:` field on each resource entry is the formal documentation mechanism for WinGet DSC configurations.

- **Mandatory**: every resource entry must include a non-empty `directives.description:` value.
- **WHY not WHAT**: the description must state the reason the resource exists and its practical effect, not merely restate the resource type or key names. For example, "Enable long path support so Nix store paths and deep Git trees do not hit the 260-character Windows limit" is better than "Enable long path support in the registry."
- **Setting rationale**: when a resource sets a non-obvious registry value, environment variable, or system flag, the description must explain what enabling or disabling the setting changes in practice.
- **Dependency rationale**: if a resource uses `dependsOn:`, the description should note why the ordering constraint exists.

## CLI option and variable naming (positive options policy)

Use `--XXX`/`--no-XXX` flag pairs for CLI options and positive variable names for scripts and config knobs. Every feature must support both `--XXX` and `--no-XXX` regardless of its default state.

| Aspect              | Convention                                          |
| ------------------- | --------------------------------------------------- |
| Shell variable      | `ai_sync=true` (positive, no prefix)                |
| Conditional check   | `if [ "$ai_sync" = false ]` or `if [ "$ai_sync" = true ]` |
| POSIX CLI flag      | `--ai-sync` (enables) / `--no-ai-sync` (disables)   |
| PowerShell param    | `[switch]$AISync` + `[switch]$NoAISync`             |
| PowerShell call     | `-AISync` (enables) / `-NoAISync` (disables)        |

Rules:

1. Every feature with a boolean CLI flag MUST support both `--XXX` and `--no-XXX` (or PowerShell equivalent: `-XXX` and `-NoXXX`).
2. Shell variables MUST use bare positive names without prefixes: `ai_sync`, `replica_sync`, `vm_setup`, `secret_health` — not `do_ai_sync`, `with_replica_sync`, etc.
3. PowerShell internal variables MUST use `$noXXX` (lowercase) for the local copy and `$NoXXX` (PascalCase) for the param variable.
4. Do not prefix with `do_`, `with_`, or any other semantic qualifier. The variable name itself is the boolean.

## Shell scripts (`scripts/**`, `src/scripts/**`)

There is no formal documentation tool for POSIX sh or Bash; `#` comments are the documentation mechanism.

- **File header**: every shell script must begin (after the shebang) with a `#` comment block that states: (1) what the script does, (2) the commands or arguments it accepts, (3) environment variables it reads, and (4) exit conditions or prerequisites.
- **Function-level comments**: every named function definition must have a `#` comment block immediately before it that states: what it does, its arguments (`# Args: $1 — …`), what it outputs or side-effects, and any noteworthy preconditions. See `scripts/bootstrap.sh` for the established pattern.
- **Non-trivial inline logic**: `case` branches, conditional chains, and environment variable reads that are not self-explanatory must have an inline `#` comment explaining the branch condition and its effect.
- **Document the WHY**: state why a particular tool or flag was chosen (e.g. "`set -a` exports all variables so child processes inherit version pins") and document any behaviour that a future reader might otherwise change incorrectly.
- **No backwards compatibility**: see [AGENTS.md#no-backwards-compatibility](../../../AGENTS.md#no-backwards-compatibility). Document the current path only.

## Citation quality

When citing external sources (APIs, documentation, vendor settings, support articles), maintain URL and content correctness to prevent drift and ensure maintainability.

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

### Topic and content verification

Before committing, verify:

1. **Article/page ID matches the claim**
   - Example: If documenting `.DS_Store` behavior, the cited Apple article must be about `.DS_Store`, not "Activation Lock" (HT102541 ≠ .DS_Store)
   - Browse the page or search the page text to confirm content matches your use case

2. **Developer vs. user scope**
   - Developer APIs should document behavior the way an SDK would
   - End-user settings/UI should match Apple's own UI documentation or end-user release notes
   - Mismatch? Add a comment explaining why the chosen source is most authoritative for your context

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

### Reviewer checklist for PR review

When reviewing changes with external citations:

- [ ] All non-trivial behavior claims have nearby citations
- [ ] API/framework claims use `developer.<vendor>.com` when available
- [ ] Any `support.apple.com/en-us/` links include `/en-us/` (no locale-less URLs)
- [ ] Cited article/page actually covers the setting/claim being documented
- [ ] No deprecated APIs cited as current behavior (or marked+explained if unavoidable)
- [ ] If a user-help page is cited over developer docs, there's a WHY comment
- [ ] All links are canonical (no query params, no obvious redirect stubs)
- [ ] Citations stay adjacent to the claim they validate

### When in doubt

- Use `developer.<vendor>.com` over user-help pages
- Add a comment explaining the choice if non-obvious
- Verify the link actually covers your use case before commit
- Include the article ID or page number for long-term reference
