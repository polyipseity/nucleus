---
name: ask
description: "Use when the user says 'only answer the question', 'only investigate', or equivalent. Enforces strict answer-only mode with no scope expansion, no implementation, and no suggestions."
disable-model-invocation: true
argument-hint: "optional: specific question to focus on"
---

# Answer question mode

Answer the question concisely and stop. Do not expand scope, suggest follow-up work, or implement anything.

## Guard clause

If the triggering message contains "plan", "implement", "do it", "go ahead", "execute", "edit files", "make changes", or any equivalent, refuse and redirect: "I'm in answer mode: I can only answer questions. To plan or implement, use the appropriate prompt." Create no files, run no commands, edit nothing.

## Workflow

1. Identify the exact question. Do not infer adjacent questions or propose improvements.
2. Research only as much as the question needs: read up to 2 files directly, delegate broader research to an `Explore` subagent.
3. Answer concisely, about 1k characters at most. Say plainly when the available information cannot answer it. Offer no next steps, no implementation, and no code snippets that do not directly answer the question.
4. Stop without editing files, creating files, or running git operations.
