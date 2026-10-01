---
description: "Use when performing commit operations. Enforces commitlint validation before every commit to ensure messages pass commit-msg hooks the first time."
name: "Commit Message Validation"
applyTo: "**"
alwaysApply: true
---

# Commit message validation

Validate every commit message with commitlint before committing:

```bash
echo "<message>" | bun x commitlint
```

Run it from the project root. Commitlint picks up `.commitlintrc.*` or `commitlint.config.*` automatically, and falls back to its conventional-commit defaults when the repo documents no conflicting convention. A documented conflict (gitmoji, `cz-customizable`, a required project format in `CONTRIBUTING.md` or `README.md`) is exempt. Silence is not.

If validation fails, fix the message and re-validate. Do not commit until it passes. If commitlint is present and configured but errors unexpectedly (a tool error, not a lint error), report the failure rather than committing.

## Temp-dir install

`bun x commitlint` writes nothing to the repo, but its cache-based resolution cannot reach packages the config's `extends` reaches from the transpiled `noop.js`, which surfaces as `Cannot find package 'conventional-changelog-conventionalcommits'`. `--default-config` is not a workaround; the global cache fails the same way. Install into a temp dir instead:

```bash
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp package.json bun.lock "$tmpdir"/
ln -s "$PWD/.commitlintrc.mjs" "$tmpdir/.commitlintrc.mjs"
(cd "$tmpdir" && bun install --frozen-lockfile --no-summary)
echo "$message" | (cd "$tmpdir" && bun run commitlint)
```

Copy whichever lockfile exists (`bun.lock`, `package-lock.json`, `yarn.lock`). With no manifest at all, copy a minimal `package.json` carrying `@commitlint/cli` and `@commitlint/config-conventional` in `devDependencies` instead: `--frozen-lockfile` is safe because bun generates a lockfile when none is copied. The commitlint config must sit inside the temp dir, since auto-discovery is cwd-based and `extends` resolves relative to the config file, not the cwd. Use `bun run commitlint` because the repo may have no `node` binary. The `trap` guarantees cleanup.

The structural check (`type(scope): subject`) is a last resort, only when `bun` is unavailable or the temp-dir install cannot complete. The pre-commit hook still enforces commitlint where it is configured.

If `node_modules/`, `package.json`, `bun.lock`, or other package-manager artifacts appear in a repo that must not have them, delete them before finishing. Never stage or commit them, and never edit `.gitignore` to hide them.

This applies to every commit: manual, automated, or through the `commit-staged` prompt.
