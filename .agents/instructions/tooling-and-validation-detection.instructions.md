---
description: "Use when creating or updating instructions for repository tooling, build commands, tests, CI, editor automation, or validation workflows. Detect the real setup from config files before documenting or prescribing commands."
name: "Tooling and Validation Detection"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.json, .vscode/settings.json, .github/workflows/**/*.yml, .github/workflows/**/*.yaml, .github/dependabot.yml, .editorconfig, .gitattributes"
---
# Tooling and Validation Detection

## Discovery before prescription

- Before documenting build, test, lint, format, type-check, packaging, release,
  or automation workflows, inspect the files that define them.
- Treat workflow files, scripts, editor settings, manifests, lockfiles, and
  config files as the primary evidence for how the repo actually works.
- If the repository is still a sparse template, describe the workflow as
  conditional or not yet initialized instead of pretending commands already
  exist.

## Command discovery

- Identify canonical commands from task-runner configs, scripts, CI steps, and
  workspace docs.
- Record where each command comes from so instructions can be updated when the
  source of truth changes.
- If several entrypoints wrap the same behavior, document the canonical one and
  note the wrappers briefly instead of duplicating the whole command matrix.

## Config coordination

- When you change an instruction about tooling, check the neighboring configs in
  the same pass:
  - CI workflows
  - editor automation
  - dependency update automation
  - formatting and line-ending config
  - prompt files that tell agents how to run checks
- Keep those files consistent so the repo does not describe one workflow while
  automating another.

## Validation guidance

- For every detected stack, document how agents should validate changes:
  - what to run
  - where the commands are defined
  - what files act as the source of truth
  - what should be avoided when the stack is only partially initialized
- When no runnable validation exists yet, say that explicitly and point to the
  files that would need to be added before validation can be automated.

## Adding new detailed instructions

- If a repository gains a clearly defined language or framework setup, add a
  dedicated instruction file for it rather than overloading generic tooling
  guidance.
- Make the added instruction thorough and evidence-backed: commands, key config
  files, source locations, testing expectations, and common failure modes.
- Keep `applyTo` globs narrow so the detailed instruction only loads for the
  files it truly governs.
