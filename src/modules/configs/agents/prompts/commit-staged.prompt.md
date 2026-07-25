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

   Prefer tooling-enforced rules; default to Conventional Commits when unclear. If the commit is rejected by commitlint, rewrap and retry with a fresh `git commit`. NEVER use `git commit --amend` — the commit was not created, so `--amend` would modify whatever HEAD currently points to (a pre-existing commit), potentially destroying history.

2a. **Verify commit** - Run `git rev-parse HEAD` and `git log -1 --format=%s`. Confirm the hash is new and the message is your intended message. If they show the previous commit's message, the commit was not created — retry with a fresh `git commit` (not `--amend`).

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
