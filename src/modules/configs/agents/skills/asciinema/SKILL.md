---
name: asciinema
version: 1.0.0
description: |
  Record terminal CLI/TUI sessions with asciinema (POSIX) / PowerSession
  (Windows) and convert to plain text for LLM context. Use when demonstrating,
  debugging, or documenting animated terminal output.
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - RunInTerminal
  - AskUserQuestion
---

# Asciinema: recording terminal sessions for LLM context

Record and convert animated terminal sessions (CLIs, TUIs, interactive programs) into plain text that LLMs can analyze. The text format strips ANSI escape codes and resolves screen overwrites, giving a clean log of what the user actually saw.

## When to use

- **Demonstrating** a CLI tool or TUI workflow to include in a prompt
- **Debugging** an interactive program that produces different output on each run
- **Documenting** terminal behavior where a static screenshot would miss intermediate states
- Any task where the agent needs to see the full timeline of terminal output, not just a single frame

## Recording

### POSIX (macOS, Linux, NixOS)

```shell
asciinema rec <file>.cast
```

Run the command, then press Ctrl+D or `exit` to stop recording. The `.cast` file contains the full terminal recording with timing information.

### Windows

```shell
PowerSession.exe rec <file>.cast
```

Run the command, then press Ctrl+C to stop recording. PowerSession is the Windows equivalent of asciinema and produces the same `.cast` format.

## Converting to text

The `.cast` file is a JSON-based recording format with embedded terminal state. To make it analyzable by an LLM, convert it to plain text:

### POSIX

```shell
asciinema convert <file>.cast <file>.txt
```

### Windows

```shell
PowerSession.exe convert <file>.cast <file>.txt
```

The conversion:

1. Strips all ANSI escape codes (colors, cursor movements, bold/italic formatting).
2. Resolves screen overwrites via the embedded `avt` (abstract virtual terminal) library — text that was displayed and then overwritten is removed from the output.
3. Produces a chronological plain-text log of the visible terminal state.

## Including in context

After conversion, include the resulting `.txt` file in the conversation context. The agent can then read the file and analyze the terminal session output.

```markdown
The `recording.txt` file contains the terminal session log. Read it to see
what happened during the interactive workflow.
```

## Cross-platform notes

| Platform              | Record tool            | Convert tool               |
| --------------------- | ---------------------- | -------------------------- |
| macOS / Linux / NixOS | `asciinema rec`        | `asciinema convert`        |
| Windows               | `PowerSession.exe rec` | `PowerSession.exe convert` |

Both tools produce the same `.cast` intermediate format and the same `.txt` output after conversion, so the workflow is identical across platforms — only the binary name differs.
