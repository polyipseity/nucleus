---
description: "Use when creating or editing nucleus-* commands and their subcommands. Covers output format, message conventions, help text, structured JSON output, and PowerShell equivalents."
name: "Nucleus Output Format"
applyTo: "scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/platforms/Windows/modules/**/*.ps1"
---

# Nucleus Command Output Format Standard

All `nucleus-*` commands must follow this output format for consistency.

## Shell scripts (`.sh`)

### Output method

Always use `printf '%s\n' "<message>"`. Never use bare `echo`.

### Message prefix

All human-readable messages use the format `<cmd>: <message>`, where `<cmd>` is the short command name (e.g., `gc`, `svc`, `config`, `check`), not the full `nucleus-*` name. The command name is derived from `basename "$0"` with the `nucleus-` prefix stripped.

### Message types

| Type | Format | Destination |
|------|--------|------------|
| Info | `<cmd>: <message>` | stdout |
| Error | `<cmd>: error: <message>` | stderr |
| Warning | `<cmd>: warning: <message>` | stderr |
| Dry-run | `<cmd>: [dry-run] <action description>` | stdout |
| Done | `<cmd>: done` | stdout |
| Section header | `\n=== [N] <Title> ===\n` | stdout |
| Timestamped (daemon only) | `[YYYY-MM-DD HH:MM:SS] <cmd>: <message>` | stdout/stderr |

Dry-run messages must always end with a newline. Do not use prose sentences like "would do X" — state the action directly.

### Help output

Every command must:

1. Define a `usage()` function that calls `usage_std` from `lib.sh`.
2. Follow with a heredoc describing subcommands/options.
3. Respond to `-h` and `--help`.
4. The `usage_std` call format: `usage_std "$(basename "$0")" "<subcommands and options summary>"`

Structure:

```sh
usage() {
  usage_std "$(basename "$0")" "list|status|start|stop [options]"
  cat <<'EOF'
  Subcommands:
    list       List all items.
    status     Show status.

  Options:
    --json     Machine-readable JSON output.
    -h|--help  Show usage.
EOF
}
```

Do not use grep-from-comments help generation, raw `echo "Usage: ..."`, or any other nonstandard mechanism.

### Shared helpers (`src/scripts/lib.sh`)

Use these functions instead of raw `printf`:

- `say "<message>"` — info message to stdout
- `error "<message>"` — error message to stderr
- `warn "<message>"` — warning message to stderr
- `dry_run "<message>"` — dry-run message to stdout
- `section "<num>" "<title>"` — section header
- `nuc_done` — completion message

These functions automatically derive the `<cmd>` prefix from the script name.

### Structured JSON output (`--json`)

When `--json` is passed:

- The entire stdout is a single JSON object or array.
- Do not mix human text and JSON in stdout.
- Errors still go to stderr as normal `<cmd>: error: ...` messages.
- Include a `"version"` field (integer) for schema evolution.
- Use `jq` to construct the JSON; never hand-roll string concatenation.

### Exit codes

- Use `set -euo pipefail` at the top of every script.
- `exit 1` on error.
- `exit 0` on success (implicit if no error).

## PowerShell scripts (`.ps1`)

### Output method

- Use `Write-Output` for info and dry-run messages.
- Use `Write-Error` for errors.
- Use `Write-Warning` for warnings.

### Message format

Same prefix convention: `"<cmd>: <message>"`, `"<cmd>: error: <message>"`, `"<cmd>: warning: <message>"`, `"<cmd>: [dry-run] <message>"`, `"<cmd>: done"`.

### Shared module

Use `Format-NucleusOutput.psm1` from `src/platforms/Windows/modules/` which provides:

- `Write-NucleusInfo <message>`
- `Write-NucleusError <message>`
- `Write-NucleusWarning <message>`
- `Write-NucleusDryRun <message>`
- `Write-NucleusDone`

### Help output

Use comment-based help (`<# ... #>`) as the formal documentation mechanism. Respond to common help flags (`-h`, `--help`, `-?`, `/?`) by showing help text.

## Example

```sh
# Good
say "processing 3 files"
error "file not found: $path"
warn "deprecated flag --old-style, use --new-style instead"
dry_run "would delete $path"
done

# Bad — bare echo, no prefix, prose dry-run
echo "processing 3 files"
echo "ERROR: file not found"
echo "would have deleted something"
```
