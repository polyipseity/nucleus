---
name: commit-staged
description: Produce a commit message for the currently staged changes and commit by default.
argument-hint: Optional extras (e.g., ticket=ABC-123). To skip committing, pass `commitNow=no`.
---

# Commit staged changes

Proceed automatically with best-effort defaults and context.

## Workflow

1. **Read staged changes**
   Run this exact command:

   ```shell
   git diff --cached --name-status --no-color && git --no-pager diff --cached --staged --patch --no-color
   ```

   If not executed, produce a best-effort commit message from context and stop.

2. **Compose commit message**
   Inspect Command 1 output and repository conventions (`CONTRIBUTING.md`, `.agents/`, `package.json`, `commitlint`, `prek.toml`, `CHANGELOG.md`, etc.). Build a commit message with:
   - Short subject (~50 chars)
   - Optional body (each line wrapped to 72 chars or fewer; bullets allowed)
   - Footer (`BREAKING CHANGE` / `Refs` / `Ticket`), including `${input:extra}` when provided

   Prefer tooling-enforced rules; default to Conventional Commits when unclear. If the commit is rejected by commitlint, rewrap and retry with a fresh `git commit`. NEVER use `git commit --amend` — the commit was not created, so `--amend` would modify whatever HEAD currently points to (a pre-existing commit), potentially destroying history. After composing, proceed to step 3 for commitlint validation.

3. **Validate with commitlint**
   Before running `git commit`, validate the message with commitlint:
   - **Detect project setup.** Check for a commitlint config file (`.commitlintrc.*`, `commitlint.config.*`) in the project root. If found, the config is used. If not found, check for a documented conflicting convention (CONTRIBUTING.md / README.md specifies a non-conventional-commit format such as `gitmoji` or a custom schema). If a conflicting convention exists AND no commitlint config is present, skip validation — the project opts out.
   - **Run validation.** From the project root:
     - **Bash/zsh:** `echo "<full message>" | bun x commitlint 2>&1`
     - **PowerShell:** `"<full message>" | bun x commitlint 2>&1`
     - **If `bun x commitlint` fails to resolve the config's `extends` deps** (e.g. `Cannot find package 'conventional-changelog-conventionalcommits'` from the config's `noop.js`), install into a temp dir and run commitlint from there — never install into the project repo:

       ```bash
       tmpdir=$(mktemp -d)
       trap 'rm -rf "$tmpdir"' EXIT
       cp package.json bun.lock "$tmpdir"/
       ln -s "$PWD/.commitlintrc.mjs" "$tmpdir/.commitlintrc.mjs"
       (cd "$tmpdir" && bun install --frozen-lockfile --no-summary)
       echo "<full message>" | (cd "$tmpdir" && bun run commitlint)
       ```

       Copy whichever lockfile exists (`bun.lock`, `package-lock.json`, `yarn.lock`). If the repo has no manifest, replace the `cp` line with a minimal `package.json` in the temp dir (devDependencies `@commitlint/cli` + `@commitlint/config-conventional`) — `--frozen-lockfile` is safe because bun generates a lockfile when none is copied. The commitlint config must live inside the temp dir (`extends` resolves relative to the config file's location, not the cwd). Use `bun run commitlint` — no `node` binary assumed. The `trap` cleans up; never create or modify `package.json`, `bun.lock`, or `node_modules` in the project repo.
     - Structural conventional-commit check (type-prefix, format) is the LAST resort: only if `bun` is unavailable or the temp-dir install cannot complete.
   - **On failure.** If validation fails AND no conflicting convention is documented, fix the message and re-run validation. Do not proceed to `git commit` until validation passes. If commitlint is present but fails with a tool error (not a lint error), report the failure — do not proceed. If the failure is `Cannot find package 'conventional-changelog-conventionalcommits'` (config `extends` unresolvable by `bun x`), use the temp-dir install fallback above — `bun x commitlint --default-config` is not a workaround.
   - **On success.** Go to step 4.

4. **Create the commit**
   If `${input:commitNow}` is `no`, skip and only present the message.
   Otherwise, run the appropriate command:
   - **PowerShell (Windows):**

     ```powershell
     (@'
     <full commit message>
     '@ | git commit --file=-) ; git rev-parse HEAD
     ```

     Use single-quoted here-strings (`@'...'@`) to avoid expansion.

   - **Bash/zsh (Linux/macOS):**

     ```bash
     (git commit --file - <<'MSG'
     <full commit message>
     MSG
     ) && git rev-parse HEAD
     ```

     Use `<<'MSG'` to prevent shell expansion. If `MSG` appears in the message, choose another delimiter.

   If heredoc quoting fails, retry up to 3 times with a different delimiter. For other failures, report the error and do not modify the index.

5. **Verify commit** - Run `git rev-parse HEAD` and `git log -1 --format=%s`. Confirm the hash is new and the message matches. If they show the previous commit's message, the commit was not created — retry with a fresh `git commit` (not `--amend`).

6. **Output**
   Staged files, detected convention, commit message, and result (SHA or skip reason).

## Rules

- Only run the two approved shell commands. Do not change the index (`git add`, `git reset`, etc.).
- Never run `bun install` or any package install to enable commitlint IN THE PROJECT REPO. If `bun x commitlint` fails to resolve config deps, install into a temp dir (`mktemp -d`) and run commitlint from there, then clean up. Never create/modify `package.json`/`bun.lock`/`node_modules` in the project. If such artifacts were accidentally created in a repository that must not have them, delete them before finishing; never commit them.

## Inputs

- `${input:extra}` — optional footer text
- `${input:commitNow}` — `no` to skip committing; defaults to commit
