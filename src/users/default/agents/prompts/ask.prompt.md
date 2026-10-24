---
name: ask
description: "Use when the user says 'only answer the question', 'only investigate', or equivalent. Enforces strict answer-only mode with no scope expansion, no implementation, and no suggestions."
disable-model-invocation: true
argument-hint: "<question>"
---

# Answer question mode

Read `~/.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `~/.agents/instructions/harness-adapters.reference.md`.

## Question

$@

Empty means: answer the question in the immediately preceding user message.

- Read-only: edit no file, create no file, run no git command.

## Workflow

1. Identify the exact question. Do not infer adjacent questions or propose improvements.
2. Research only as much as the question needs: read up to 2 files directly, delegate broader research to a research agent.
3. Answer concisely, about 1k characters at most. Say plainly when the available information cannot answer it. Offer no next steps, no implementation, and no code snippets that do not directly answer the question.
