---
description: "Use when working with shell scripts in the repository. Covers shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "**"
---

# ShellCheck policy

## Suppression rules

- **Every `# shellcheck disable=` must have an inline `# reason` comment** on the same line, documenting why the suppression is necessary, what constraint prevents the code from being rewritten to avoid the warning, and (if applicable) why the trigger is a false positive.

  Example: `# shellcheck disable=SC2086 # word splitting intentional for rclone flag passthrough`

- **Neither SC1090 nor SC1091 may be suppressed.** Both must always be resolved with `# shellcheck source=` directives pointing from the repo root so shellcheck can follow the sourced file during static analysis. The Nix build mirrors the repo structure exactly, so directives that work in the source tree also work in the build — there is never a structural mismatch.

  Example: a script at `src/scripts/services/foo.sh` sourcing `src/scripts/lib/lib.sh` adds `# shellcheck source=../lib/lib.sh` before `. "$SCRIPT_DIR/../lib/lib.sh"`.

  The sole exception is when the sourced file genuinely cannot exist at shellcheck analysis time (e.g., `$HOME/.nix-profile/etc/profile.d/nix.sh` sourced by bootstrap.sh — created at runtime by the Nix installer). In that case: (a) an inline `# reason` comment must justify the exception, and (b) the directive `# shellcheck source=` approach is impossible because the path is genuinely unreachable. No other exceptions are permitted.

- **Suppressions in vendored third-party code** (`vendor/`) are exempt from this policy. The repo's shellcheck invocations skip vendor directories.

## Shellcheck invocation

All shell scripts are checked with `check-sh.sh`, which invokes:

```
shellcheck --source-path=SCRIPTDIR -x <files>
```

The Nix build system uses `--source-path=$out` against the bundled mirror tree so `# shellcheck source=` directives resolve identically to the source tree.

When adding new shell scripts, ensure they pass shellcheck with these flags. Do not add new scripts with pre-existing suppression warnings unless documented per the rules above.
