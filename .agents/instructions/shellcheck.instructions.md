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

- **Suppressions in vendored third-party code** (`vendor/`) are exempt from this policy. The repo's shellcheck invocations skip vendor directories via `git ls-files` pathspecs.

- **File-level suppressions are prohibited.** Every `# shellcheck disable=` must be scoped to the smallest possible range: inline on the same line as the triggered code, or wrapped in a `disable`/`enable` pair around a multi-line expression. Placing a disable directive at the top of a file before any commands is forbidden — no exceptions.

### Priority guidance

When evaluating whether to suppress or rewrite, use this priority to assess risk:

- **SC2086 (word splitting) — highest priority to eliminate.** Suppress only when the variable is intentionally passed to a command that requires word-split arguments (rclone flags, glob patterns, find type lists). Quote every argument that should stay atomic.
- **SC2064 (trap with variable expansion) — must restructure to single-quoted trap form.** The expansion at trap time is intentional, but single-quoted form preserves identical semantics when the variable is set before the trap and never reassigned. Convert `trap "...$VAR..."` to `trap '..."$VAR"...'`. Suppression only if the variable genuinely must be expanded at trap-definition time (rare).
- **SC2016 (literal `$` in single quotes) — restructure first: for awk scripts longer than ~10 lines, extract to a `.awk` file referenced via `-f`. This eliminates the suppression entirely. For small awk one-liners, jq filters, sed scripts, and other tool-specific strings where `$` is not shell expansion, use a line-scoped suppression with reason. Acceptable contexts include: awk script bodies, jq filter variables (`$var`), `sh -c` child-shell parameter expansion, tool expression strings (yq paths, PowerShell redirection patterns, regex metacharacters), and literal text matching with `grep -F`. Suppress with reason.
- **SC2154/SC2034 (referenced but not assigned / unused) — must fix root cause (prefer runtime library import via `source` with `# shellcheck source=`) over suppression.** The root cause is typically build-time string concatenation (Nix prepend) that hides variable assignment from shellcheck. Fix by having scripts source libs at runtime via SCRIPT_DIR-relative paths and adding `# shellcheck source=` directives. Suppression only for genuinely untraceable framework-injected vars (e.g., nix-direnv `_nix_direnv_nix` set in user-specific paths).
- **SC2194 (constant in loop) — template placeholder must use `__PLACEHOLDER__` convention with intermediate variable.** Replace `case "{{PLACEHOLDER}}"` with `HOST_KIND="__HOST_KIND__"; case "$HOST_KIND"`. Shellcheck sees a variable expansion and does not fire SC2194. The `__PLACEHOLDER__` format also avoids false matches with Mustache/Handlebars syntax. Suppression only for build-time-only templates that shellcheck never evaluates.**

### Reference table

| SC code | Trigger | Canonical fix strategy |
|---------|---------|----------------------|
| SC2016 | Literal `$` in single quotes | Extract awk scripts to `.awk` files; line-scoped suppression for small tool-specific strings with `# reason:` comment |
| SC2034 | Variable assigned but never used | Pass variable as function argument or `export` for consumed-by-sourced-file pattern |
| SC2064 | Double-quoted trap | Convert to single-quoted trap preserving same variable references |
| SC2086 | Word splitting | Quote the variable; suppress only for intentional word-split flag passthrough |
| SC2154 | Variable referenced but not assigned | Add runtime source with `# shellcheck source=` directive; suppress only for unreachable framework-injected vars |
| SC2194 | Constant as `case` subject | Replace `{{PLACEHOLDER}}` with `__PLACEHOLDER__` + intermediate variable |

## Script file conventions

All scripts that source other files MUST use SCRIPT_DIR-style relative pathing:

```sh
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/relative/path"
```

This ensures scripts work from any cwd, prevents `CDPATH` interference, and
resolves symlinks to physical paths (matching nix store resolution). See
`scripts-and-permissions.instructions.md` (Relative pathing convention) for the
full convention.

## Shellcheck invocation

All shell scripts are checked with `check-sh.sh`, which invokes:

```shell
shellcheck --source-path=SCRIPTDIR -x <files>
```

The Nix build system uses `--source-path=$out` against the bundled mirror tree so `# shellcheck source=` directives resolve identically to the source tree.

When adding new shell scripts, ensure they pass shellcheck with these flags. Do not add new scripts with pre-existing suppression warnings unless documented per the rules above.
