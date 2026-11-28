---
description: "Use when working with shell scripts and shellcheck suppressions."
name: "ShellCheck Policy"
applyTo: "scripts/**/*.sh, src/scripts/**/*.sh, src/vms/**/*.sh, tests/**/*.sh"
---

# ShellCheck policy

## Suppression rules

Rewrite first: quote the variable, use a static `# shellcheck source=` path, or restructure the line. Suppression is the last resort.

- Every `# shellcheck disable=` needs `# reason:` on the same line; step 11 fails without it.
- A continuation line under a shellcheck directive must not start with `# shellcheck` (SC1072, SC1073).
- SC1090 and SC1091 may never be suppressed; use `# shellcheck source=`. Directives resolve against each script's directory because `src/treefmt.nix` sets `source-path = "SCRIPTDIR"`. A file absent at analysis time, such as `$HOME/.nix-profile/etc/profile.d/nix.sh` in `bootstrap.sh`, is the one exception and still needs `# reason:`.
- No file-level suppressions. Scope to the line, or wrap multi-line expressions in `disable`/`enable`.
- `vendor/` is exempt; invocations skip it.

| Code | Trigger | Fix |
| --- | --- | --- |
| SC2086 | Word splitting | Quote, unless the split is intentional passthrough (rclone flags, globs, find type lists) |
| SC2064 | Double-quoted trap | Single-quoted trap, unless expansion at definition time is required |
| SC2016 | Literal `$` in single quotes | Extract awk over 10 lines to `.awk`; suppress small tool strings (awk, jq, sed, `sh -c`, `grep -F`) with a reason |
| SC2154, SC2034 | Var unassigned or unused | Add a runtime `source` with `# shellcheck source=`; suppress only framework-injected vars such as `_nix_direnv_nix` |
| SC2194 | Constant `case` subject | Use an `__PLACEHOLDER__` intermediate; suppress only build-time templates |

## Script conventions

Source relative to the script's own directory: `SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"`, then `. "$SCRIPT_DIR/relative/path"`. `pwd -P` resolves symlinks; `CDPATH=''` blocks interference. Symlink-reached scripts use `dirname -- "$_self"`. See `script-authoring.instructions.md`.

Keep `jq 'program'` and `"$FILE"` on one line: a quote on its own line is a command separator and jq hangs. Add `|| return` and have tests redirect stdin from `/dev/null`.

## Invocation

Shellcheck runs inside treefmt-nix, never at Nix build time. Entry points: `nucleus-check sh` and CI (`scripts/check.sh` step 01, `scripts/check.sh sh`, `scripts/check.ps1 sh` with `shellcheck.exe -x -S style` and per-file `--source-path`). `src/treefmt.nix` sets `enable`, `source-path = "SCRIPTDIR"`, `external-sources`, and `severity = "style"`.

Severity is `style` everywhere, so any finding fails. Never raise it to `warning` or `error`. New scripts pass clean; surviving suppressions carry `# reason:`.
