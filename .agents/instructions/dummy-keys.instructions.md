---
description: "Use when adding or editing dummy/placeholder API keys in tracked configs, updating the dummy-key registry, or touching the step 13 repository-policy check."
name: "Dummy Key Management"
applyTo: "src/modules/dummy-keys.json, src/modules/dummy-keys.schema.json, src/scripts/checks/check-steps/13-repository-policy.*, src/users/*/cursor/mcp.json"
---

# Dummy Key Management

The canonical dummy-key registry lives at `src/modules/dummy-keys.json`, validated against `src/modules/dummy-keys.schema.json`.

## Policy

- Any dummy/placeholder API-key literal of the form `sk-` followed by 4+ alphanumerics that is hardcoded in a tracked config must resolve to a registered `dummyKeys.<name>.value`.
- Add new dummy keys to the registry with three fields: `value` (the exact literal consumers must use), `consumers` (repo-relative paths of configs using it), and `note` (why the dummy key exists).
- Consumers must use the registry `value` verbatim — no re-typing, no variant spellings, no inline substitutions.
- Check step 13 (`run_13_dummy_key_uniformity` in `src/scripts/checks/check-steps/13-repository-policy.sh` / `.ps1`) enforces registration; keep the check in sync with any registry shape changes.
