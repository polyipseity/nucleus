---
description: "Use when working with shell scripts in the repository. Shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "scripts/**/*.sh, src/scripts/**/*.sh, src/vms/**/*.sh, tests/**/*.sh"
---

# ShellCheck policy

## Suppression rules

Rewrite first: quote the variable, use a static `# shellcheck source=` path, or restructure the line. Suppression is the last resort.

- Every `# shellcheck disable=` needs `# reason:` on the same line. Step 11 fails a suppression line without it.
- A continuation line under a `# shellcheck` directive never starts with `# shellcheck`; that reads as a malformed directive (SC1072, SC1073).
- SC1090 and SC1091 may never be suppressed; use `# shellcheck source=`. Directives resolve against each script's own directory, since `src/treefmt.nix` sets `source-path = "SCRIPTDIR"`. The one exception is a file that cannot exist at analysis time, such as `$HOME/.nix-profile/etc/profile.d/nix.sh` in `bootstrap.sh`, which still needs a `# reason:`.
- No file-level suppressions. Scope to the triggered line, or wrap a multi-line expression in `disable`/`enable`.
- `vendor/` is exempt; shellcheck invocations skip it.

| Code | Trigger | Fix |
| --- | --- | --- |
| SC2086 | Word splitting | Quote, unless the split is intentional passthrough (rclone flags, globs, find type lists) |
| SC2064 | Double-quoted trap | Convert to a single-quoted trap, unless the variable must expand at definition time |
| SC2016 | Literal `$` in single quotes | Extract awk over 10 lines to a `.awk` file; suppress small tool strings (awk, jq, sed, `sh -c`, `grep -F`) with a reason |
| SC2154, SC2034 | Var unassigned or unused | Add a runtime `source` with `# shellcheck source=`; suppress only framework-injected vars such as `_nix_direnv_nix` |
| SC2194 | Constant as `case` subject | Use an `__PLACEHOLDER__` intermediate variable; suppress only build-time templates |

## Script conventions

Source relative to the script's own directory, with `SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"` and `. "$SCRIPT_DIR/relative/path"`. `pwd -P` resolves symlinks and `CDPATH=''` blocks interference. Scripts reached through a symlink use `dirname -- "$_self"`. See `script-authoring.instructions.md`.

Keep `jq 'program'` and `"$FILE"` on the same line: a quote on its own line is a command separator and jq hangs. Add `|| return`, and have tests redirect stdin from `/dev/null`.

## Invocation

Shellcheck runs inside treefmt-nix, never at Nix build time, so `nucleus-check sh` and CI are the entry points (`scripts/check.sh` step 01, `scripts/check.sh sh`, `scripts/check.ps1 sh` with `shellcheck.exe -x -S style` and a per-file `--source-path`). `src/treefmt.nix` sets `enable`, `source-path = "SCRIPTDIR"`, `external-sources`, and `severity = "style"`.

Severity is `style` at every invocation, so any finding at any level fails. Never raise it to `warning` or `error`. New scripts pass clean; surviving suppressions carry a `# reason:`.
