---
description: "Use when working with shell scripts and shellcheck suppressions."
name: "ShellCheck Policy"
applyTo: "scripts/**/*.sh, src/scripts/**/*.sh, src/vms/**/*.sh, tests/**/*.sh"
---

# ShellCheck policy

Rewrite before suppressing: quote, use a static `# shellcheck source=`, or restructure. Every `# shellcheck disable=` needs `# reason:` on the same line; continuation lines must not start with `# shellcheck`. SC1090 and SC1091 are never suppressed; directives resolve against the script's own directory (`source-path = "SCRIPTDIR"`), with a file-absent-at-analysis exception that still needs `# reason:`. No file-level suppressions; `vendor/` is exempt.

Common fixes: SC2086 quote unless intentional passthrough, SC2064 single-quoted trap, SC2016 extract awk over 10 lines, SC2154/SC2034 add a runtime source or suppress framework vars, SC2194 use an `__PLACEHOLDER__`. Keep `jq 'program'` and `"$FILE"` on one line and add `|| return`.

Shellcheck runs through treefmt-nix at `style` severity, never at Nix build time; entry points are `nucleus-check sh` and CI. Any finding fails; never raise severity to warning or error. Details: `.agents/skills/nucleus-platform-reference/references/shellcheck.md`.
