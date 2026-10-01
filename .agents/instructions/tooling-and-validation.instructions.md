---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and validation

Read the tree before writing about it: manifests, lockfiles, lint configs, CI, scripts, editor settings, source layout. Describe a stack as conditional when the repo barely uses it. Take canonical commands from the task-runner configs, scripts, and CI, and name the wrappers briefly instead of listing them.

`AGENTS.md` holds durable conventions, `.instructions.md` holds file-type-scoped rules under a narrow `applyTo`, and `SKILL.md` is an on-demand reference that must not repeat `AGENTS.md`. Change a tooling instruction and the configs beside it in the same pass; take test counts from the current `tests/` tree, not from prose.

GitHub CLI runs noninteractive: `GH_PROMPT_DISABLED=1`, `GH_PAGER=cat`, prefer `--json`/`--jq`, never `gh run watch`.

## Tool availability

No skip-guards. A missing tool fails loudly: provisioning installs it, preflight verifies it and hard-fails. Banned: `command -v <tool> || return 0`, `Get-Command -ErrorAction SilentlyContinue` gating, `Test-Path` skip-guards. Allowed: picking between equivalent tools, `exit 1` in preflight, config-driven optional features. Scope: `scripts/`, `tests/`, `src/scripts/`, `src/platforms/Windows/modules/`.

## Check script structure

Steps are grouped and numbered from the `check-steps/<nn>-*` filenames, so opening a group means renumbering. A new tool goes into both preflight and provisioning. The step filenames and header docstrings are the source of truth: a step's platform, mode, and prerequisites are declared at its `register_step` call, and transcribing them into prose only produces a copy that drifts.

A step that resolves `<nixpkgs>` pins it with `nucleus_pin_nixpkgs <repo_root>` (`src/scripts/lib/step-runner.sh`) before the first nix invocation; the machine's `<nixpkgs>` is never used.

Scoped mode keys off `_has_args`: POSIX steps read `ctx[HAS_ARGS]`/`ctx[REPO_ROOT]` plus the trailing file args, PowerShell steps read `$Context.HasArgs`/`$Context.RepoRoot`/`$Context.PositionalArgs`. A path-scopable step filters what it is given and treats an empty match set as nothing to check. A whole-repo-only step declares `mode full` at registration and the runner reports it `not applicable (mode: full)`. Wrap an empty PowerShell pipeline in `@(...)` before `.Count`, with a `# WHY:`.

## Stack specifics

- Nix formatting is treefmt only. No separate `format-nix` hook.
- `nixf-tidy < file` reads stdin; the positional form hangs. Run it before Nix test edits.
- In tests, every deadnix finding is real (lazy evaluation). Remove the binding or force it with `builtins.seq (builtins.deepSeq { ... } null)`. `deepSeq` takes two arguments; one argument is a partial lambda and yields dead assertions.
- Commit validation is commitlint through `prek.toml`, with the upstream type preset. Pre-validate from a temp dir with `bun install`, because bare `bun x` cannot resolve the config's `extends` deps. Remove the temp artifacts afterwards.
- prek installs always and stays idempotent. It refuses an external `core.hooksPath` with exit 2. `repo-check` and `repo-test` carry `require_serial = true` to avoid cache races. Warm the cache from the git real path, not a symlink, since those use different cache databases. Never `treefmt --no-cache`. Subagents never commit or push.
- No new checks or tests go into `ci.yml`; route them into the repo check or test steps.

Validate every changed file type, and cite a source inline for any identifier nothing validates. When no runnable validation exists, say so and name the files needed.
