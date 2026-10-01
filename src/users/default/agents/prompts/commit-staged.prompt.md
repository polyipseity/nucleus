---
name: commit-staged
description: Produce a commit message for the currently staged changes and commit by default.
disable-model-invocation: true
argument-hint: Optional extras (e.g., ticket=ABC-123). To skip committing, pass `commitNow=no`.
---

# Commit staged changes

Proceed automatically with best-effort defaults and context.

## Workflow

1. **Read the staged changes** with this exact command:

   ```shell
   git diff --cached --name-status --no-color && git --no-pager diff --cached --staged --patch --no-color
   ```

   If it has not run, write a best-effort message from context and stop.

2. **Compose the message** from that output and the repository's own conventions (`.agents/`, `CONTRIBUTING.md`, `package.json`, commitlint config, `prek.toml`): a short subject around 50 chars, an optional body with each line 72 chars or fewer, and a footer (`BREAKING CHANGE`, `Refs`, `Ticket`) that includes `${input:extra}` when given. Prefer whatever tooling enforces; fall back to Conventional Commits. If commitlint rejects the message, rewrap it and retry with a fresh `git commit`.

   Never use `git commit --amend`. A rejected commit was never created, so `--amend` would rewrite whatever HEAD points at and destroy a pre-existing commit.

3. **Validate with commitlint** before committing, unless the project documents a conflicting convention (gitmoji, custom schema) and ships no commitlint config. Run `echo "<full message>" | bun x commitlint 2>&1` in bash/zsh or `"<full message>" | bun x commitlint 2>&1` in PowerShell. When `bun x` cannot resolve the config's `extends` deps (`Cannot find package 'conventional-changelog-conventionalcommits'`), install into a temp dir and run from there; `--default-config` is not a workaround:

     ```bash
     tmpdir=$(mktemp -d)
     trap 'rm -rf "$tmpdir"' EXIT
     cp package.json bun.lock "$tmpdir"/
     ln -s "$PWD/.commitlintrc.mjs" "$tmpdir/.commitlintrc.mjs"
     (cd "$tmpdir" && bun install --frozen-lockfile --no-summary)
     echo "<full message>" | (cd "$tmpdir" && bun run commitlint)
     ```

     Copy whichever lockfile exists (`bun.lock`, `package-lock.json`, `yarn.lock`); with no manifest, write a minimal `package.json` carrying `@commitlint/cli` and `@commitlint/config-conventional` instead of the `cp` line. The commitlint config must live inside the temp dir, because `extends` resolves relative to the config file, not the cwd. Use `bun run commitlint`, since no `node` binary is assumed. Never create or modify `package.json`, `bun.lock`, or `node_modules` in the project.

   A structural check of the `type(scope): subject` shape is the last resort, for when bun is unavailable or the temp install cannot complete. On a lint failure, fix the message and re-run, and do not commit until it passes; on a tool error, report it and stop.

4. **Create the commit.** If `${input:commitNow}` is `no`, present the message and stop. Otherwise:

   PowerShell (Windows), with a single-quoted here-string so nothing expands:

   ```powershell
   (@'
   <full commit message>
   '@ | git commit --file=-) ; git rev-parse HEAD
   ```

   Bash/zsh (Linux/macOS), with `<<'MSG'` to prevent shell expansion; pick another delimiter if `MSG` appears in the message:

   ```bash
   (git commit --file - <<'MSG'
   <full commit message>
   MSG
   ) && git rev-parse HEAD
   ```

   Retry a failed heredoc quoting up to 3 times with a different delimiter. For any other failure, report the error and leave the index alone.

5. **Verify.** Run `git rev-parse HEAD` and `git log -1 --format=%s`. The hash must be new and the message must match. Seeing the previous commit's message means nothing was created: retry with a fresh `git commit`, never `--amend`.

6. **Report** the staged files, the convention detected, the message, and the result (SHA or skip reason).

## Rules

- Run only the two approved shell commands. Do not touch the index: no `git add`, no `git reset`.
- Never run `bun install` or any install to enable commitlint inside the project repo. Use a temp dir (`mktemp -d`) and clean it up. If artifacts such as `node_modules/`, `package.json`, or a lockfile were created in a repo that must not have them, delete them before finishing and never commit them.

## Inputs

- `${input:extra}`: optional footer text
- `${input:commitNow}`: `no` to skip committing; defaults to commit
