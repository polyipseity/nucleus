---
name: asciinema
version: 2.0.0
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

### Important: final state only

`asciinema convert txt` renders only the **final visible screen state** — the encoder calls `feed_str()` for every event but `flush()` once at the end, discarding intermediate frames. No `--fps` or equivalent exists on `asciinema convert` or `play`.

## Frame-by-frame extraction

When you need the individual screen states over time (e.g., for animating a progress bar or seeing partial output that gets overwritten), `asciinema convert txt` is insufficient. Here is what exists and what does not.

### Landscape summary

| Tool | Output | Frame-by-frame text? | Notes |
| ---- | ------ | -------------------- | ----- |
| Python `pyte` script (below) | Plain text | Yes (real terminal emulator) | `pip install pyte`; pure Python VT100 emulator, handles cursor moves, clears, scrolls |
| Node.js `@xterm/headless` script (below) | Plain text | Yes (real terminal emulator) | `npm install @xterm/headless`; official xterm.js headless, full xterm compatibility |
| Everything else (`asciinema convert txt`, `agg`, `svg-term-cli`, `asciicast-to-svg`, etc.) | Image / final-only text | No | No existing CLI outputs frame-by-frame text — the scripts below fill this gap |

### What actually works

#### For Python environments: pyte terminal emulator

[`pyte`](https://github.com/selectel/pyte) is a pure Python VT100-compatible terminal emulator (747 stars, 1.5K dependents). It is actively maintained (latest release Nov 2023, Python 3.10+). Install with:

```shell
pip install pyte
```

The following script replays an asciicast through a real terminal emulator and captures unique screen states at a configurable interval:

```python
import json
import pyte


def process_asciinema_to_timeline(input_path, output_path, debounce_sec=0.2):
    """Replay an asciicast through pyte and capture screen states."""
    events = []
    cols, rows = 80, 24
    with open(input_path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('{'):
                try:
                    header = json.loads(line)
                    cols = header.get('width', 80)
                    rows = header.get('height', 24)
                except json.JSONDecodeError:
                    pass
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, list) and len(event) >= 3 and event[1] == 'o':
                events.append((float(event[0]), event[2]))

    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)
    timeline = []
    last_saved = ""
    last_time = 0.0

    for timestamp, data in events:
        stream.feed(data)
        if timestamp - last_time >= debounce_sec:
            snapshot = '\n'.join(screen.display).rstrip()
            if snapshot and snapshot != last_saved:
                timeline.append({"timestamp": f"{timestamp:.3f}", "content": snapshot})
                last_saved = snapshot
            last_time = timestamp

    with open(output_path, 'w', encoding='utf-8') as out:
        out.write("# Reconstructed terminal timeline\n\n")
        for frame in timeline:
            out.write(f"### Timestamp {frame['timestamp']}s\n")
            out.write(f"```text\n{frame['content']}\n```\n\n")


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} <input.cast> [output.md] [debounce_sec]")
        sys.exit(1)
    output = sys.argv[2] if len(sys.argv) > 2 else 'ai_ready_timeline.md'
    debounce = float(sys.argv[3]) if len(sys.argv) > 3 else 0.2
    process_asciinema_to_timeline(sys.argv[1], output, debounce)
```

After generating the timeline, prefix the output with this analysis prompt before feeding it to a downstream LLM:

```text
The text below is a state-deduplicated, chronological timeline of a terminal
session reconstructed from an asciinema cast file using a terminal emulator.
Transient animations and duplicate frames have been filtered out.

Analyze the sequence and provide:
1. Executive summary: what main task or process was the user executing?
2. Commands run: every core CLI tool or command invoked.
3. Error detection: any stack traces, HTTP errors, compilation failures,
   or non-zero exit codes?
4. Final state: what was the terminal left showing at the last timestamp?

--- LOG START ---
[CONTENT OF ai_ready_timeline.md]
--- LOG END ---
```

**Token-budget safety**: if the output is too large, re-run with a higher `debounce_sec` (e.g., `1.0` or `2.0`).

**Caveat**: pyte emulates VT100/linux, not xterm. Most CLI tools work, but some xterm-specific escapes may not render exactly.

#### For Node.js environments: xterm-headless

[`@xterm/headless`](https://www.npmjs.com/package/@xterm/headless) is the official headless terminal emulator from the xterm.js project (804K weekly downloads, v6.0.0). It runs in Node.js without a browser.

```shell
npm install @xterm/headless
```

```javascript
import { Terminal } from '@xterm/headless';
import { readFileSync, writeFileSync } from 'fs';

async function processAsciicast(inputPath, outputPath, debounceSec = 0.2) {
  const text = readFileSync(inputPath, 'utf-8');
  const lines = text.trim().split('\n');

  // Parse header (first line is a JSON object)
  const header = JSON.parse(lines[0]);
  const cols = header.width || 80;
  const rows = header.height || 24;

  // Parse events
  const events = [];
  for (let i = 1; i < lines.length; i++) {
    try {
      const ev = JSON.parse(lines[i]);
      if (Array.isArray(ev) && ev.length >= 3 && ev[1] === 'o') {
        events.push({ time: ev[0], data: ev[2] });
      }
    } catch {}
  }

  // Set up terminal
  const term = new Terminal({ cols, rows });

  const timeline = [];
  let lastSaved = '';
  let lastTime = 0;

  for (const { time, data } of events) {
    term.write(data);

    if (time - lastTime >= debounceSec) {
      // Extract text from the terminal buffer
      const buffer = term.buffer.active;
      const lines = [];
      for (let y = 0; y < buffer.length; y++) {
        const line = buffer.getLine(y);
        if (line) {
          lines.push(line.translateToString().trimEnd());
        }
      }
      const snapshot = lines.join('\n').trimEnd();
      if (snapshot && snapshot !== lastSaved) {
        timeline.push({ timestamp: time.toFixed(3), content: snapshot });
        lastSaved = snapshot;
      }
      lastTime = time;
    }
  }

  // Write markdown
  let md = '# Reconstructed terminal timeline\n\n';
  for (const frame of timeline) {
    md += `### Timestamp ${frame.timestamp}s\n`;
    md += '```text\n' + frame.content + '\n```\n\n';
  }
  writeFileSync(outputPath, md, 'utf-8');
}

processAsciicast('input.cast', 'ai_ready_timeline.md');
```

**Caveats**:
- `@xterm/headless` is experimental per its own docs. The API may change between versions.
- Requires Node.js 18+.

#### Other approaches (less practical)

- **svg-term-cli --at**: renders frames as SVG; brittle to scrape `<text>` elements from — multi-line output is lossy.
- **avt Rust library**: the canonical frame loop (`Vt::builder()` → `feed_str()` → `Snapshot::from_vt()` → `same_visual()` dedup) but requires a custom Rust program; no prebuilt CLI exposes it.
- **asciicast-to-svg .text()**: npm package with a `.text()` method returning raw terminal text, but stepping all frames needs manual `stdout` event iteration.
- **Headless browser + asciinema player**: seek via JS API and extract DOM text — works but heavy overhead (Puppeteer/Playwright).

### asciicast v3 format primer

The `.cast` file is JSON-lines: a header line (JSON object with `width`, `height`) followed by event lines `[timestamp, type, data]`. Event types: `'o'` (output), `'i'` (input), `'r'` (resize), `'m'` (marker), `'x'` (exit).

```shell
wc -l recording.cast           # count events
head -1 recording.cast         # see header (has width, height)
grep '"o"' recording.cast | head -20  # see output events
grep '"o"' recording.cast | cut -d, -f1 | tr -d '[' | head -20  # timestamps only
```

Common quirks:
- **Bulk data at t=0**: Most terminals dump the entire initial state at `0.000` seconds. The actual animation may be a short burst (e.g., 0.050–0.072s). You must replay through a terminal emulator to resolve it.
- **Scrollback**: Default avt `save_screen` captures 100 history lines. Use `scrollback_limit(0)` for visible screen only.

## Including in context

After conversion, include the `.txt` file in context:

```markdown
The `recording.txt` file contains the terminal session log. Read it to see
what happened during the interactive workflow.
```
