---
description: "Use when working with shell scripts in the repository. Covers shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "**"
---

# ShellCheck policy

## Suppression rules

- **Every `# shellcheck disable=` must have an inline `# reason` comment** on the same line, documenting why the suppression is necessary, what constraint prevents the code from being rewritten to avoid the warning, and (if applicable) why the trigger is a false positive.

  Example: `# shellcheck disable=SC2086 # word splitting intentional for rclone flag passthrough`

- **SC1091 must not be suppressed.** Shellcheck's `--source-path` and `-x` flags resolve source directives when scripts are checked with the canonical invocation (`check-sh.sh`). If a `source` can't be resolved, fix the invocation or the source path — do not add `# shellcheck disable=SC1091`.

  The sole exception is when the sourced file genuinely cannot exist at shellcheck analysis time (e.g., generated at runtime by Nix installer during bootstrap). In that case, the inline comment must explain the technical constraint.

- **Suppressions in vendored third-party code** (`vendor/`) are exempt from this policy. The repo's shellcheck invocations skip vendor directories.

## Shellcheck invocation

All shell scripts are checked with `check-sh.sh`, which invokes:

```
shellcheck --source-path=SCRIPTDIR -x <files>
```

The Nix build system (`writeShellApplicationWithLib` in `flake.nix`) uses the equivalent:

```
shellcheck --source-path="$out/bin" -x "$out/bin/$name"
```

When adding new shell scripts, ensure they pass shellcheck with these flags. Do not add new scripts with pre-existing suppression warnings unless documented per the rules above.
