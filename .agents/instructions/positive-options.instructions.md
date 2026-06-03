---
description: "Use when adding CLI options, script variables, or config knobs across the nucleus repo. Enforces positive-only naming to avoid double negation."
name: "Positive Options Policy"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1, src/hosts/Windows/**/*.yml"
---

Positive-options policy for nucleus source files:

- Every CLI flag, script variable, and configuration switch must be named as a
  positive action: `do_X`, `with_X`, `enable_X`, or `use_X`.
- Forbidden patterns: `skip_*`, `--skip-*`, `-Skip*`, `--no-*`, `disable_*`,
  `suppress_*` as opt-out prefixes.
- Exception: `--dry-run` / `-DryRun` is a mode selector, not an opt-out — it is
  allowed.
- POSIX CLI convention: use `--with-X` for opt-in features, `--without-X` for
  opt-out of on-by-default features.
- PowerShell convention: use `-WithX` / `-WithoutX` matching.
- Default values must be chosen so every enabled/active check reads
  `if [ "$do_X" = true ]` or `if ($DoX)` — never `if [ "$skip_X" = false ]`.
- When a step runs by default, name it `do_*` / `-Do*` with default `true` and
  `--without-X` to opt out.
- When a step is opt-in (off by default), name it `with_*` / `-With*` with
  default `false` and `--with-X` to opt in.
