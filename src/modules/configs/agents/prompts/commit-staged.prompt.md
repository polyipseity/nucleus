---
name: commit-staged
description: Produce a commit message for the currently staged changes and commit by default.
argument-hint: Optional extras (e.g., ticket=ABC-123). To skip committing, pass `commitNow=no`.
---

# Commit staged change

Proceed automatically with best-effort defaults and available context.

## Workflow

1. **Read staged changes**
   Run this exact command:

   ```shell
   git diff --cached --name-status --no-color && git --no-pager diff --cached --staged --patch --no-color
   ```

   If not executed, produce a best-effort commit message from available context and stop.

2. **Compose commit message**
   Inspect Command 1 output and repository conventions (`CONTRIBUTING.md`, `.agents/`, `package.json`, `commitlint`, `prek.toml`, `CHANGELOG.md`, etc.). Build a commit message with:
   - Short subject (~50 chars)
   - Optional body (each line wrapped to 72 chars or fewer; bullets allowed)
   - Footer (`BREAKING CHANGE` / `Refs` / `Ticket`), including `${input:extra}` when provided

   Prefer tooling-enforced rules; default to Conventional Commits when unclear. After composing, proceed to step 2b for commitlint validation.

2b. **Validate with commitlint**
   Before running `git commit`, validate the message with commitlint:

   - **Detect project setup.** Check for a commitlint config file (`.commitlintrc.*`, `commitlint.config.*`) in the project root. If found, the config is used. If not found, check for a documented conflicting convention (CONTRIBUTING.md / README.md specifies a non-conventional-commit format such as `gitmoji` or a custom schema). If a conflicting convention exists AND no commitlint config is present, skip validation entirely — the project has explicitly opted out.
   - **Run validation.** From the project root:
     - **Bash/zsh:** `echo "<full message>" | bun x commitlint 2>&1`
     - **PowerShell:** `"<full message>" | bun x commitlint 2>&1`
     - If `bun` / `commitlint` is unavailable, fall back to a structural conventional-commit check (type-prefix, format).
   - **On failure.** If validation fails AND no conflicting convention is documented, fix the message and re-run validation. Do not proceed to `git commit` until validation passes. If commitlint is present but fails with a tool error (not a lint error), report the failure — do not proceed.
   - **On success.** Proceed to step 2c.

2c. **Verify commit** - Run `git rev-parse HEAD` and `git log -1 --format=%s`. Confirm the hash is new and the message is your intended message. If they show the previous commit's message, the commit was not created — retry with a fresh `git commit` (not `--amend`).

3. **Create the commit**
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

4. **Output**
   Summary of staged files, detected convention, commit message, and result (SHA or skip reason).

## Rules

- Only run the two approved shell commands. Do not change the index (`git add`, `git reset`, etc.).

## Inputs

- `${input:extra}` — optional footer text
- `${input:commitNow}` — `no` to skip committing; defaults to commit
