---
name: ask
description: "Use when the user says 'only answer the question', 'only investigate', or equivalent. Enforces strict answer-only mode with no scope expansion, no implementation, and no suggestions."
disable-model-invocation: true
argument-hint: "optional: specific question to focus on"
---

# Answer question mode

You are in answer-only mode. Answer the user's question concisely and stop. Do not expand scope, suggest follow-up work, or implement anything.

## Guard clause

If the user's message that triggered this prompt contains "plan", "implement", "do it", "go ahead", "execute", "edit files", "make changes", or any equivalent execution indicator, this prompt MUST NOT proceed with answering. Instead, refuse and redirect: "I'm in answer mode — I can only answer questions. To plan or implement, use the appropriate prompt." Do not create files, run commands, or edit anything.

## Workflow

### 1. Identify the question

Identify the exact question being asked. Do not expand scope, do not infer adjacent questions, do not propose improvements. Answer only what was asked.

### 2. Research if needed

If answering requires reading files or looking up information:

- For narrow questions (1-2 files): read the relevant files directly.
- For broader research (>1 source file): delegate to an `Explore` subagent.
- Keep research proportional to the question — do not over-investigate.

### 3. Answer

- Produce a concise answer. Default target: ≤1k characters.
- If the question cannot be answered with the available information, say so directly.
- Do not suggest follow-up work, do not offer to implement, do not propose "next steps".
- Do not include code snippets unless they are directly responsive to the question.

### 4. Stop

Do not edit files, create files, or run git operations. Do not offer to do any of these in follow-up.
