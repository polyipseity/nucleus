---
description: "Use when performing commit operations. Enforces commitlint validation before every commit to ensure messages pass commit-msg hooks the first time."
name: "Commit Message Validation"
applyTo: "**"
---

# Commit message validation

## Core rule

Validate every commit message with commitlint *before* calling `git commit`. Run:

```bash
echo "<message>" | bun x commitlint
```

from the project root. If a commitlint config exists (`.commitlintrc.*`, `commitlint.config.*`), it is used automatically. If no config is found and no conflicting convention is documented, commitlint validates with its conventional-commit defaults.

### No package installation to enable commitlint

NEVER run `bun install`, `npm install`, `yarn`, or any other package-manager install to enable commitlint. NEVER create or modify `package.json`, `bun.lock`, `package-lock.json`, `yarn.lock`, or `node_modules/` for this purpose. `bun x` needs no install step — it fetches the requested package into a per-run temp dir (`/tmp/bunx-*`) plus a global cache (`~/.bun/install/cache`) and never writes to the repository.

If commitlint is not available (`bun` not found or `bun x commitlint` fails), fall back to a structural check: ensure the message follows conventional-commit format (`type(scope): subject`). The pre-commit hook will still enforce commitlint if configured. Never attempt to install commitlint or any of its dependencies as a workaround.

If `node_modules/`, `package.json`, `bun.lock`, or other package-manager artifacts were accidentally created in a repository that must not have them, delete them before finishing the task. Never stage or commit them, and never edit `.gitignore` to hide them.

## Exception: conflicting conventions

Projects that explicitly document a conflicting convention (in `CONTRIBUTING.md`, `README.md`, or equivalent) are exempt. A conflicting convention means the project specifies a non-conventional-commit format — e.g. `gitmoji`, `cz-customizable` with a custom schema, or a project-specific format documented as required.

Absence of a documented convention does **not** qualify as conflicting — the default conventional-commit validation applies.

## Failure behavior

If commitlint validation fails AND no conflicting convention is documented, fix the message and re-validate before attempting `git commit`. Do not proceed to `git commit` until validation passes.

### Config-extension resolution failure

If `bun x commitlint` fails with `Cannot find module "@commitlint/config-conventional"` (or similar), the repository's commitlint config `extends` a package that commitlint cannot resolve without a local install. Do NOT install the package to fix this. Either run `echo "<message>" | bun x commitlint --default-config` (validates against commitlint's bundled conventional defaults, ignoring the custom config's `ignores`) or fall back to the structural check. The repository's real commit-msg hook enforces the actual config with its own dependency setup.

If commitlint is present and configured but fails unexpectedly (tool error, not lint error), report the failure — do not proceed with the commit. This follows the no-fallbacks principle.

## Enforcement scope

This instruction applies to every `git commit` operation: manual, automated, and via the `commit-staged` prompt. See `commit-staged.prompt.md` for the standard workflow that includes this validation.

## Related instruction files

- `commit-safety.instructions.md` — Post-commit verification, amend prohibition, and hook failure recovery.
- `commit-staged.prompt.md` — Full staged-commit workflow with commitlint pre-validation built in.
- `core-behavior.instructions.md` — Git commit enforcement policy and commit-keeper subagent delegation.
