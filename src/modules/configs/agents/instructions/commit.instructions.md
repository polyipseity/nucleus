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

### Temp-dir install fallback (never in the repo)

`bun x commitlint` needs no install — it fetches the requested package into a per-run temp dir (`/tmp/bunx-*`) plus a global cache (`~/.bun/install/cache`) and never writes to the repository. If `bun x commitlint` fails to resolve the config's `extends` dependencies (see below), run commitlint from a temp dir with `bun install`:

```bash
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp package.json bun.lock "$tmpdir"/
ln -s "$PWD/.commitlintrc.mjs" "$tmpdir/.commitlintrc.mjs"
(cd "$tmpdir" && bun install --frozen-lockfile --no-summary)
echo "$message" | (cd "$tmpdir" && bun run commitlint)
```

Copy whichever lockfile exists (`bun.lock`, `package-lock.json`, or `yarn.lock`). If the repo has no manifest at all, write a minimal `package.json` into the temp dir instead (devDependencies `@commitlint/cli` + `@commitlint/config-conventional`) so the install still works. The commitlint config must live inside the temp dir: auto-discovery is cwd-based, and `extends` resolves relative to the config file's location, not the cwd. Use `bun run commitlint` — the repo may have no `node` binary. The `trap` guarantees cleanup; the repo is never touched (no `node_modules/`, no `package.json`/lockfile edits).

The structural check (`type(scope): subject`) is the LAST resort: only when `bun` is unavailable or the temp-dir install cannot complete (e.g. no network). The pre-commit hook will still enforce commitlint if configured.

If `node_modules/`, `package.json`, `bun.lock`, or other package-manager artifacts were accidentally created in a repository that must not have them, delete them before finishing the task. Never stage or commit them, and never edit `.gitignore` to hide them.

## Exception: conflicting conventions

Projects that explicitly document a conflicting convention (in `CONTRIBUTING.md`, `README.md`, or equivalent) are exempt. A conflicting convention means the project specifies a non-conventional-commit format — e.g. `gitmoji`, `cz-customizable` with a custom schema, or a project-specific format documented as required.

Absence of a documented convention does **not** qualify as conflicting — the default conventional-commit validation applies.

## Failure behavior

If commitlint validation fails AND no conflicting convention is documented, fix the message and re-validate before attempting `git commit`. Do not proceed to `git commit` until validation passes.

### Config-extension resolution failure

If `bun x commitlint` fails with `Cannot find module "@commitlint/config-conventional"` (or similar), the repository's commitlint config `extends` a package that `bun x`'s cache-based resolution cannot reach. Use the temp-dir install fallback above. `--default-config` is NOT a workaround: bun's global cache cannot resolve `conventional-changelog-conventionalcommits` from the transpiled `noop.js` either (verified in nucleus). The repository's real commit-msg hook enforces the actual config with its own dependency setup.

If commitlint is present and configured but fails unexpectedly (tool error, not lint error), report the failure — do not proceed with the commit. This follows the no-fallbacks principle.

## Enforcement scope

This instruction applies to every `git commit` operation: manual, automated, and via the `commit-staged` prompt. See `commit-staged.prompt.md` for the standard workflow that includes this validation.

## Related instruction files

- `commit-safety.instructions.md` — Post-commit verification, amend prohibition, and hook failure recovery.
- `commit-staged.prompt.md` — Full staged-commit workflow with commitlint pre-validation built in.
- `core-behavior.instructions.md` — Git commit enforcement policy and commit-keeper subagent delegation.
