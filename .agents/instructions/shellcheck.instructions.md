---
description: "Use when working with shell scripts in the repository. Covers shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "**"
---

# ShellCheck policy

## Suppression rules

- **Prefer rewriting over suppressing.** Before adding a `# shellcheck disable=`, first attempt to restructure the code to satisfy shellcheck: quote the variable, use a static source path for `# shellcheck source=`, or break the line into separate statements. Suppression is the last resort, not the first reflex.

- **Every `# shellcheck disable=` must have an inline `# reason:` comment** (with colon) on the same line, documenting why the suppression is necessary, what constraint prevents the code from being rewritten to avoid the warning, and (if applicable) why the trigger is a false positive. Format: `# shellcheck disable=SCXXXX # reason: <justification>`. The `reason:` prefix is mandatory — bare `# text` comments do not count.

  Example: `# shellcheck disable=SC2086 # reason: word splitting intentional for rclone flag passthrough`

- **Neither SC1090 nor SC1091 may be suppressed.** Both must always be resolved with `# shellcheck source=` directives pointing from the repo root so shellcheck can follow the sourced file during static analysis. The Nix build mirrors the repo structure exactly, so directives that work in the source tree also work in the build — there is never a structural mismatch.

  Example: a script at `src/scripts/services/foo.sh` sourcing `src/scripts/lib/lib.sh` adds `# shellcheck source=../lib/lib.sh` before `. "$SCRIPT_DIR/../lib/lib.sh"`.

  The sole exception is when the sourced file genuinely cannot exist at shellcheck analysis time (e.g., `$HOME/.nix-profile/etc/profile.d/nix.sh` sourced by bootstrap.sh — created at runtime by the Nix installer). In that case: (a) an inline `# reason` comment must justify the exception, and (b) the directive `# shellcheck source=` approach is impossible because the path is genuinely unreachable. No other exceptions are permitted.

- **Review new suppressions twice.** Before adding a new `# shellcheck disable=`, ask: "Can I quote the variable? Can I use a static path? Can I restructure the expression?" If the answer to all is no, the suppression is justified. Any suppression that survives this self-review must have a `# reason:` comment that documents the attempted alternatives and why they failed.

- **Suppressions in vendored third-party code** (`vendor/`) are exempt from this policy. The repo's shellcheck invocations skip vendor directories.

### Priority guidance

When evaluating whether to suppress or rewrite, use this priority to assess risk:

- **SC2086 (word splitting) — highest priority to eliminate.** Suppress only when the variable is intentionally passed to a command that requires word-split arguments (rclone flags, glob patterns, find type lists). Quote every argument that should stay atomic.

- **SC2064 (trap with variable expansion) — acceptable when PID/tmpfile intent is explicit.** The expansion at trap time is intentional. Suppress with reason.

- **SC2016 (literal `$` in single quotes) — acceptable when the string is an awk/jq/sed script body, regex pattern, or PowerShell code passed to another interpreter. Suppress with reason.

- **SC2154/SC2034 (referenced but not assigned / unused) — acceptable when variables are set by sourced libs, framework code, or infrastructure. Prefer adding `# shellcheck source=` to let shellcheck follow the source and see the assignment. If the source cannot be statically resolved, suppress with reason.

- **SC2194 (constant in loop) — acceptable only for template placeholders that are substituted at instantiation time.

## Shellcheck invocation

All shell scripts are checked with `check-sh.sh`, which invokes:

```
shellcheck --source-path=SCRIPTDIR -x <files>
```

The Nix build system uses `--source-path=$out` against the bundled mirror tree so `# shellcheck source=` directives resolve identically to the source tree.

When adding new shell scripts, ensure they pass shellcheck with these flags. Do not add new scripts with pre-existing suppression warnings unless documented per the rules above.
