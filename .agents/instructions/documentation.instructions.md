---
description: "Use when adding or editing any infrastructure code: Nix files, PowerShell modules, WinGet DSC YAML, or shell scripts. Mandates documentation standards for each file type and applies the WHY-not-WHAT commenting principle."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/windows/**/*.yml, scripts/**, src/scripts/**"
---

# Documentation Standards

Every piece of infrastructure code must be documented using the formal
mechanism available for its file type. When no formal mechanism exists, inline
`#` comments are required instead.

The guiding principle is **document the WHY, not the WHAT**: record the
rationale, security implication, or design tradeoff behind a decision — not a
restatement of what the code already says. Avoid obvious comments.

## Nix files (`src/**/*.nix`)

There is no Nix-native documentation tool in use here; inline `#` comments are
the documentation mechanism.

- **File header**: every `.nix` file must open with a `#` comment stating the
  file path relative to `src/`, a dash, and a plain-language description of the
  module's purpose and scope.
  Example: `# modules/shell.nix — Interactive shell configuration for all hosts.`
- **Non-trivial `let` bindings**: every helper function, derived value, or
  multi-step computation in a `let` block needs at least one `#` comment
  explaining what it computes and why it exists — not just naming it.
- **`system.activationScripts` and `home.activation` entries**: each entry must
  have a banner comment (separator line + entry name + purpose + algorithm notes)
  explaining what the script does, what invariant it maintains, and any side
  effects. See `modules/macos.nix` for the established pattern.
- **Module options (`lib.mkOption`)**: the `description` field is the formal
  documentation mechanism for Nix module options and is mandatory on every
  `mkOption` call. The description must explain what the option controls and
  what effect different values have, not merely restate the type.
- **Non-obvious inline code**: `builtins.*` calls, `lib.*` expressions, and
  config block patterns that are not immediately self-evident to a reader
  unfamiliar with Nix or this codebase must have a `#` comment explaining
  the purpose.
- **Document the WHY**: prefer comments that explain the rationale, security
  implication, or design tradeoff behind a setting (e.g. why a PAM service name
  was chosen, why an option combination closes a specific attack surface) over
  comments that merely describe what the option does.

## PowerShell files (`src/**/*.ps1`)

Comment-based help (`<# … #>`) is the formal documentation mechanism for
PowerShell and is required on every function and entry-point script.

- **Script-level help**: every `.ps1` script that is invoked as an entry point
  must open with a `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>`
  block placed directly before the `[CmdletBinding()]` or `param(…)` declaration.
- **Function-level help**: every `function Verb-Noun { … }` must have its own
  `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .OUTPUTS … .EXAMPLE … #>` block.
  Required sections: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per
  parameter), `.EXAMPLE`. Add `.OUTPUTS` whenever the function returns a value.
- **Inline logic comments**: non-trivial logic blocks, exit-code checks, and
  PowerShell idioms that are not immediately obvious must have an inline `#`
  comment explaining what the block does and, where relevant, why this approach
  was chosen over alternatives.
- **Document the WHY**: record the rationale behind security-sensitive patterns
  (e.g. "env var cleared in `finally` so it is never left in the environment on
  failure") and any non-obvious fallback behaviour or error handling choices.

### Explicit Parameter Passing Requirement (PowerShell)

**No implicit defaults, no auto-derived paths, no backwards compatibility code.**

All PowerShell functions and scripts must enforce explicit parameter passing:

- **Mandatory behavioral parameters**: all parameters that control system state
  changes (e.g. `Enabled`, `Users`, `Activated`) must be `[Parameter(Mandatory)]`.
  Callers must explicitly choose `$true` or `$false` — never default to "enabled"
  or "process current user."
- **No path auto-derivation**: do not auto-derive paths from `$PSScriptRoot` or
  current working directory. All path parameters must be explicitly passed by
  callers so they are aware of which repository, module directory, or user
  home will be modified.
- **Explicit user context**: functions that operate on user profiles or home
  directories must have explicit `-Username` or `-Users` parameters. Never
  assume the current user or auto-discover users from filesystem locations.
- **No backwards compatibility code**: remove deprecated parameters, conditional
  fallback logic, and migration shims. If a feature no longer exists or has been
  restructured, document the change clearly in examples and breaking change
  notes. Repository history is preserved in Git; code does not need to support
  old incompatible configurations.
- **Documentation examples must be complete**: every `.EXAMPLE` block must show
  all mandatory parameters. Use canonical usernames in examples: `admin` for
  primary/elevated user, `guest` for secondary/unprivileged users. This ensures
  examples are copy-paste-ready and reflect the actual calling convention.

## WinGet DSC YAML (`src/hosts/windows/**/*.yml`)

The `directives.description:` field on each resource entry is the formal
documentation mechanism for WinGet DSC configurations.

- **Mandatory**: every resource entry must include a non-empty
  `directives.description:` value.
- **WHY not WHAT**: the description must state the reason the resource exists
  and its practical effect, not merely restate the resource type or key names.
  For example, "Enable long path support so Nix store paths and deep Git trees
  do not hit the 260-character Windows limit" is better than "Enable long path
  support in the registry."
- **Setting rationale**: when a resource sets a non-obvious registry value,
  environment variable, or system flag, the description must explain what
  enabling or disabling the setting changes in practice.
- **Dependency rationale**: if a resource uses `dependsOn:`, the description
  should note why the ordering constraint exists.

## Shell scripts (`scripts/**`, `src/scripts/**`)

There is no formal documentation tool for POSIX sh or Bash; `#` comments are
the documentation mechanism.

- **File header**: every shell script must begin (after the shebang) with a
  `#` comment block that states: (1) what the script does, (2) the commands or
  arguments it accepts, (3) environment variables it reads, and (4) exit
  conditions or prerequisites.
- **Function-level comments**: every named function definition must have a `#`
  comment block immediately before it that states: what it does, its arguments
  (`# Args: $1 — …`), what it outputs or side-effects, and any noteworthy
  preconditions. See `scripts/bootstrap.sh` for the established pattern.
- **Non-trivial inline logic**: `case` branches, conditional chains, and
  environment variable reads that are not self-explanatory must have an inline
  `#` comment explaining the branch condition and its effect.
- **Document the WHY**: state why a particular tool or flag was chosen (e.g.
  "`set -a` exports all variables so child processes inherit version pins") and
  document any behaviour that a future reader might otherwise change
  incorrectly.
