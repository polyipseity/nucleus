---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and validation

Read the tree before describing a stack; take commands from task configs, scripts, and CI. `AGENTS.md` holds durable conventions, `.instructions.md` holds file-scoped rules, and `SKILL.md` is on-demand and does not repeat `AGENTS.md`. GitHub CLI runs noninteractive (`GH_PROMPT_DISABLED=1`, `GH_PAGER=cat`, `--json`/`--jq`, never `gh run watch`).

No skip guards: a missing tool hard-fails; provisioning installs and preflight verifies. Steps are numbered from `check-steps/<nn>-*`, and their `register_step` calls are the source of truth for platform, mode, and prerequisites. A step resolving `<nixpkgs>` pins it with `nucleus_pin_nixpkgs` before nix runs. Scoped mode keys off `_has_args` (POSIX `ctx[HAS_ARGS]`, PowerShell `$Context.HasArgs`). `check.sh`, `test.sh`, and `update.sh` require bash 5.1; `bootstrap.sh` stays 3.2 compatible.

Nix format is treefmt only; `nixf-tidy < file`; deadnix findings are real; commitlint runs through prek; prek hooks stay idempotent with `require_serial` and never use `treefmt --no-cache`. No new checks go into `ci.yml`. Validate every changed file type and cite a source for identifiers nothing validates.

Details: `src/users/default/agents/skills/nucleus-citation-reference/references/tooling-and-validation.md`.
