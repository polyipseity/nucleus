---
description: "Use when working with shell scripts in the repository. Covers shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "scripts/**/*.sh, src/scripts/**/*.sh, src/vms/**/*.sh, tests/**/*.sh"
---

# ShellCheck policy

## Suppression rules

- **Prefer rewriting over suppressing.** Before adding a `# shellcheck disable=`, first attempt to restructure the code to satisfy shellcheck: quote the variable, use a static source path for `# shellcheck source=`, or break the line into separate statements. Suppression is the last resort, not the first reflex.

- **Every `# shellcheck disable=` must have an inline `# reason:` comment** (with colon) on the same line, documenting why the suppression is necessary, what constraint prevents the code from being rewritten to avoid the warning, and (if applicable) why the trigger is a false positive. Format: `# shellcheck disable=SCXXXX # reason: <justification>`. The `reason:` prefix is mandatory — bare `# text` comments do not count.

  Example: `# shellcheck disable=SC2086 # reason: word splitting intentional for rclone flag passthrough`

- **Neither SC1090 nor SC1091 may be suppressed.** Both must always be resolved with `# shellcheck source=` directives so shellcheck can follow the sourced file during static analysis. Directives resolve relative to each script's own directory because treefmt-nix runs shellcheck with `source-path = "SCRIPTDIR"` (`src/treefmt.nix`) — a directive that works in the source tree also works wherever treefmt runs, since it is always anchored to the script's directory, never to the repo root.

  Example: a script at `src/scripts/services/foo.sh` sourcing `src/scripts/lib/lib.sh` adds `# shellcheck source=../lib/lib.sh` before `. "$SCRIPT_DIR/../lib/lib.sh"`.

  The sole exception is when the sourced file genuinely cannot exist at shellcheck analysis time (e.g., `$HOME/.nix-profile/etc/profile.d/nix.sh` sourced by bootstrap.sh — created at runtime by the Nix installer). In that case: (a) an inline `# reason` comment must justify the exception, and (b) the directive `# shellcheck source=` approach is impossible because the path is genuinely unreachable. No other exceptions are permitted.

- **Review new suppressions twice.** Before adding a new `# shellcheck disable=`, ask: "Can I quote the variable? Can I use a static path? Can I restructure the expression?" If the answer to all is no, the suppression is justified. Any suppression that survives this self-review must have a `# reason:` comment that documents the attempted alternatives and why they failed.

- **Suppressions in vendored third-party code** (`vendor/`) are exempt from this policy. The repo's shellcheck invocations skip vendor directories via `git ls-files` pathspecs.

- **File-level suppressions are prohibited.** Every `# shellcheck disable=` must be scoped to the smallest possible range: inline on the same line as the triggered code, or wrapped in a `disable`/`enable` pair around a multi-line expression. Placing a disable directive at the top of a file before any commands is forbidden — no exceptions.

### Priority guidance

When evaluating whether to suppress or rewrite, use this priority to assess risk:

- **SC2086 (word splitting) — highest priority to eliminate.** Suppress only when the variable is intentionally passed to a command that requires word-split arguments (rclone flags, glob patterns, find type lists). Quote every argument that should stay atomic.
- **SC2064 (trap with variable expansion) — must restructure to single-quoted trap form.** The expansion at trap time is intentional, but single-quoted form preserves identical semantics when the variable is set before the trap and never reassigned. Convert `trap "...$VAR..."` to `trap '..."$VAR"...'`. Suppression only if the variable genuinely must be expanded at trap-definition time (rare).
- \*\*SC2016 (literal `$` in single quotes) — restructure first: for awk scripts longer than ~10 lines, extract to a `.awk` file referenced via `-f`. This eliminates the suppression entirely. For small awk one-liners, jq filters, sed scripts, and other tool-specific strings where `$` is not shell expansion, use a line-scoped suppression with reason. Acceptable contexts include: awk script bodies, jq filter variables (`$var`), `sh -c` child-shell parameter expansion, tool expression strings (yq paths, PowerShell redirection patterns, regex metacharacters), and literal text matching with `grep -F`. Suppress with reason.
- **SC2154/SC2034 (referenced but not assigned / unused) — must fix root cause (prefer runtime library import via `source` with `# shellcheck source=`) over suppression.** The root cause is typically build-time string concatenation (Nix prepend) that hides variable assignment from shellcheck. Fix by having scripts source libs at runtime via SCRIPT_DIR-relative paths and adding `# shellcheck source=` directives. Suppression only for genuinely untraceable framework-injected vars (e.g., nix-direnv `_nix_direnv_nix` set in user-specific paths).
- **SC2194 (constant in loop) — template placeholder must use `__PLACEHOLDER__` convention with intermediate variable.** Replace `case "{{PLACEHOLDER}}"` with `HOST_KIND="__HOST_KIND__"; case "$HOST_KIND"`. Shellcheck sees a variable expansion and does not fire SC2194. The `__PLACEHOLDER__` format also avoids false matches with Mustache/Handlebars syntax. Suppression only for build-time-only templates that shellcheck never evaluates.\*\*

### Reference table

| SC code | Trigger                              | Canonical fix strategy                                                                                                |
| ------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| SC2016  | Literal `$` in single quotes         | Extract awk scripts to `.awk` files; line-scoped suppression for small tool-specific strings with `# reason:` comment |
| SC2034  | Variable assigned but never used     | Pass variable as function argument or `export` for consumed-by-sourced-file pattern                                   |
| SC2064  | Double-quoted trap                   | Convert to single-quoted trap preserving same variable references                                                     |
| SC2086  | Word splitting                       | Quote the variable; suppress only for intentional word-split flag passthrough                                         |
| SC2154  | Variable referenced but not assigned | Add runtime source with `# shellcheck source=` directive; suppress only for unreachable framework-injected vars       |
| SC2194  | Constant as `case` subject           | Replace `{{PLACEHOLDER}}` with `__PLACEHOLDER__` + intermediate variable                                              |

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

- **jq with a file argument**: keep the closing quote of the `jq 'program'` and the `"$FILE"` argument on the SAME line. A closing single-quote on its own line followed by args on the next line is a command separator — bash splits one command into two (jq hangs reading stdin; the file becomes a new command). Add `|| return` so jq failures are visible; tests invoking jq should redirect stdin from `/dev/null` so a stdin-blocking jq fails fast instead of hanging.

## Shellcheck invocation

Shell scripts are linted via treefmt (ShellCheck runs inside treefmt-nix):

1. **`scripts/check.sh`** (pre-commit, via `prek-hooks.py`): step 01-code-formatting runs `treefmt`, which invokes ShellCheck with the settings in `src/treefmt.nix`.
2. **`scripts/check-sh.sh`** (standalone): the canonical shell lint runner, invoked directly. It runs `treefmt --fail-on-change` over `git ls-files '*.sh' ':(exclude)vendor/'`. ShellCheck settings live in `src/treefmt.nix`:

   ```nix
   shellcheck = {
     enable = true;
     # resolves `# shellcheck source=` directives relative to each script's directory
     source-path = "SCRIPTDIR";
     # follow external sourced files (required for source-path to work)
     external-sources = true;
     # lowest severity so ALL findings fail the build
     severity = "style";
   };
   ```

3. **Windows** (`scripts/check-sh.ps1`): runs `shellcheck.exe -x -S style` directly (treefmt is Nix-only on POSIX hosts); it passes `--source-path` per file for parity with treefmt's `SCRIPTDIR`.

ShellCheck does NOT run at Nix derivation build time (`src/modules/lib/script-tree.nix` documents this); it runs in `nucleus-check-sh` / CI only.

The `--source-path` values differ between source and Nix build but both resolve the same
`# shellcheck source=` directives because the SCRIPT_DIR-relative path structure is
identical in both contexts.

When adding new shell scripts, ensure they pass shellcheck with these flags. Do not add
new scripts with pre-existing suppression warnings unless documented per the rules above.

## Severity enforcement

All shellcheck invocations in this repository explicitly pass
`--severity=style` (the lowest severity level). There is no severity
threshold — **any** shellcheck finding, regardless of its severity
classification, causes the step to fail. Do not add `--severity`
overrides that raise the threshold (e.g. `--severity=warning` or
`--severity=error`). If a new shellcheck invocation point is added,
it must also pass `-S style`.
