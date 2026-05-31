---
name: commit-staged
description: Produce a commit message for the currently staged changes and commit by default.
argument-hint: Optional extras (e.g., ticket=ABC-123). To skip committing, pass `commitNow=no`.
---

# Commit staged change

Proceed automatically with best-effort defaults and available context. Do not ask
for confirmation.

## Workflow

1. **Read staged changes**
   - Run this exact command to print the staged file list and full staged patch:

     ```shell
     git diff --cached --name-status --no-color && git --no-pager diff --cached --staged --patch --no-color
     ```

   - Present the exact command before execution.
   - If not executed, produce a best-effort commit message from available context
     and stop.

2. **Compose commit message**
   - Inspect Command 1 output and repository conventions
     (`CONTRIBUTING.md`, `.agents/`, `package.json`, `commitlint`, `prek.toml`,
     `CHANGELOG.md`, etc.).
   - Build a commit message with:
     - Short subject (~50 chars)
     - Optional body (each line wrapped to 72 chars or fewer; bullets allowed)
     - Footer (`BREAKING CHANGE` / `Refs` / `Ticket`), including
       `${input:extra}` when provided
   - Prefer tooling-enforced rules; default to Conventional Commits when unclear.
   - If commitlint rejects line length or formatting, rewrap and retry until it
     passes.
   - Do not ask for confirmation before committing.

3. **Create the commit**
   - If `${input:commitNow}` is `no`, skip this step and only present the
     message.
   - Otherwise, present the exact command to commit from stdin and print the new
     SHA. Run both parts in the same shell command block.
   - Use shell-appropriate syntax:
     - **PowerShell (Windows):**

       ```powershell
       (@'
       <full commit message>
       '@ | git commit --file=-) ; git rev-parse HEAD
       ```

       Prefer single-quoted here-strings (`@'...'@`) to avoid expansion.

     - **Bash/zsh (Linux/macOS):**

       ```bash
       (git commit --file - <<'MSG'
       <full commit message>
       MSG
       ) && git rev-parse HEAD
       ```

       Use `<<'MSG'` to prevent shell expansion. If `MSG` appears in the message,
       choose another delimiter.

   - If Command 2 fails due to quoting/heredoc syntax, retry up to 3 corrected
     forms. For other failures, report the error and do not modify the index.

4. **Output**
   - 1–2 line summary with staged files and detected convention
   - `Commit message` block (header/body/footer)
   - If Command 2 ran: `Commit result` with exit status and new commit SHA
   - 1–3 line justification for fit

## Rules

- Never ask for confirmation or clarification.
- Only run the two approved shell commands. Do not run `git add`, `git reset`,
  or otherwise change the index.
- If Command 1 is denied, still propose a best-effort commit message from
  available context.

## Inputs

- `${input:extra}` — optional extra text for footer
- `${input:commitNow}` — `no` to skip committing; default is to commit
