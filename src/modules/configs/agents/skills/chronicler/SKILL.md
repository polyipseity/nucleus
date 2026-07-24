---
name: chronicler
version: 1.0.0
description: |
  Analyze Copilot session history for standup reports, usage tips, session search,
  and session reindexing. Use when the user asks for a standup, daily summary,
  usage tips, workflow recommendations, wants to search or find past sessions by
  keyword/file/PR, wants to reindex their session store, or asks about deleting
  session data.
allowed-tools:
  - SessionStoreSql
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

# Chronicler: session history analysis

Analyze the local Copilot session store to provide daily standups, usage tips, session search, reindexing, and improvement suggestions.

## Schema reference

| Table | Key columns | Purpose |
|-------|-------------|---------|
| `sessions` | `id`, `repository`, `agent_name`, `summary`, `created_at` | One row per chat session |
| `turns` | `session_id`, `turn_index`, `user_message`, `assistant_response` | Individual messages within a session |
| `session_files` | `session_id`, `file_path`, `tool_name` | Files accessed during a session |
| `session_refs` | `session_id`, `ref_type`, `ref_value` | External references (issues, PRs, commits) |
| `search_index` | FTS5 virtual table with `content`, `session_id`, `source_type`, `source_id` | Full-text search over session content |
| `checkpoints` | `session_id`, `checkpoint_number`, `title`, `overview`, `work_done`, `next_steps` | Conversation summaries saved via /checkpoint |

## Subcommands

### `tips`
Query usage patterns: most-edited files, common errors, agent usage trends, repo activity distribution.
- Use `GROUP BY` and `COUNT(*)` on `sessions.repository`, `session_files.file_path`, `turns.assistant_response` patterns.

### `standup`
Summarize the last 24 hours: sessions per repo, key activities, files touched.
- Pre-fetch data with `action: 'standup'` for efficiency.
- Filter with `WHERE s.created_at >= datetime('now', '-1 day')`.

### `search`
Full-text search over session content.
- Use FTS5 `MATCH` syntax on `search_index`: `SELECT * FROM search_index WHERE content MATCH ?`.
- Joins: `search_index JOIN sessions ON search_index.session_id = sessions.id`.

### `reindex`
Rebuild the search index from debug logs.
- Use `action: 'reindex'` with `force: true` to reprocess all sessions.
- Normal (no force) skips already-indexed sessions.

### `improve`
Analyze session patterns to suggest agent setup improvements.
- Look at common errors, frequently-accessed files, repetitive user corrections.
- Cross-reference with existing `~/.agents/instructions/` to identify gaps.

## Parameter conventions

- Always set `subcommand: "tips"` on every `session_store_sql` call for telemetry.
- Use `description` with a 2-5 word summary of what the call does.

## SQL idioms

- Date math: `datetime('now', '-1 day')` — NOT `now() - INTERVAL '1 day'` (this is SQLite, not PostgreSQL).
- FTS5 text search: `SELECT * FROM search_index WHERE content MATCH 'search terms'`.
- Only read-only queries: `SELECT` and `WITH` only (the tool enforces this).
