---
description: "Use when working with shell scripts in the repository. Shellcheck suppression rules: mandatory inline reason comments, SC1091 prohibition, and invocation conventions."
name: "ShellCheck Policy"
applyTo: "scripts/**/*.sh, src/scripts/**/*.sh, src/vms/**/*.sh, tests/**/*.sh"
---

# ShellCheck policy

## Suppression rules

- **Prefer rewriting over suppressing.** Quote the variable, use a static `# shellcheck source=` path, or restructure the line. Suppression is the last resort.
- **Every `# shellcheck disable=` must have `# reason:` on the same line** documenting why rewriting failed. Format: `# shellcheck disable=SCXXXX # reason: <justification>`. The `reason:` prefix is mandatory.
  Example: `# shellcheck disable=SC2086 # reason: word splitting intentional for rclone flag passthrough`
- **SC1090/SC1091 may not be suppressed.** Always use `# shellcheck source=` directives. Directives resolve relative to each script's directory (treefmt-nix uses `source-path = "SCRIPTDIR"` in `src/treefmt.nix`).
  Exception: sourced file cannot exist at analysis time (e.g. `$HOME/.nix-profile/etc/profile.d/nix.sh` in `bootstrap.sh` — created at runtime). Justify with `# reason`; no other exceptions.
- **Review before suppressing.** Ask: can I quote? Can I use a static path? Can I restructure? Surviving suppressions need `# reason:` documenting attempted alternatives.
- **Vendored code** (`vendor/`) is exempt — shellcheck invocations skip vendor directories.
- **No file-level suppressions.** Scope to the triggered line, or wrap in a `disable`/`enable` pair for multi-line expressions.

### Priority guidance

- **SC2086** — suppress only for intentional word-split args (rclone flags, globs, find type lists). Quote everything else.
- **SC2064** — restructure to single-quoted trap. Suppress only if variable must expand at definition time.
- **SC2016** — awk >10 lines: extract to `.awk` file. Small tool strings (awk one-liners, jq, sed, `sh -c`, `grep -F`): suppress with reason.
- **SC2154/SC2034** — fix via runtime `source` with `# shellcheck source=`. Suppress only for untraceable framework vars (e.g. nix-direnv `_nix_direnv_nix`).
- **SC2194** — use `__PLACEHOLDER__` intermediate variable. Suppress only for build-time-only templates.

### Reference table

| Code | Trigger | Fix |
| --- | --- | --- |
| SC2016 | Literal `$` in single quotes | Extract awk to `.awk` file; suppress small tool strings with `# reason:` |
| SC2034 | Variable assigned but unused | Pass as function arg or `export` for sourced-file consumption |
| SC2064 | Double-quoted trap | Convert to single-quoted trap |
| SC2086 | Word splitting | Quote variable; suppress only for intentional word-split passthrough |
| SC2154 | Variable referenced not assigned | Add runtime `source` with `# shellcheck source=`; suppress only framework-injected vars |
| SC2194 | Constant as `case` subject | Replace `{{PLACEHOLDER}}` with `__PLACEHOLDER__` + intermediate variable |

## Script file conventions

SCRIPT_DIR-style relative pathing for sourcing:

```sh
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/relative/path"
```

Cwd-independent, CDPATH-safe, symlink-resolving. See `script-authoring.instructions.md`.

**jq with file argument**: keep `jq 'program'` and `"$FILE"` on the same line — a quote on its own line is a command separator (jq hangs). Add `|| return`; tests redirect stdin from `/dev/null`.

## Shellcheck invocation

Runs inside treefmt-nix (not at Nix build time — `nucleus-check sh` / CI only).

**Settings** (`src/treefmt.nix`):

```nix
shellcheck = {
  enable = true;
  source-path = "SCRIPTDIR";
  external-sources = true;
  severity = "style";  # all findings fail the build
};
```

**Entry points:** `scripts/check.sh` pre-commit (step 01 via treefmt), `scripts/check.sh sh` standalone, `scripts/check.ps1 sh` (Windows: `shellcheck.exe -x -S style` with per-file `--source-path`).

`source-path` anchors to each script's directory, so `# shellcheck source=` directives work identically everywhere shellcheck runs. New scripts must pass shellcheck with these flags — no pre-existing suppressions unless documented above.

## Severity enforcement

All shellcheck invocations use `--severity=style` (lowest level). Any finding at any severity fails the build. Do not raise the threshold (`--severity=warning` or `--severity=error`). New invocation points must also pass `-S style`.
