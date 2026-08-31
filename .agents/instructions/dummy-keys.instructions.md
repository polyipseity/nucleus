---
description: "Use when adding or editing dummy/placeholder API keys in tracked configs, updating the dummy-key registry, or touching the step 14 repository-policy check."
name: "Dummy Key Management"
applyTo: "src/modules/dummy-keys.json, src/modules/dummy-keys.schema.json, src/scripts/checks/check-steps/14-repository-policy.*, src/users/*/cursor/mcp.json"
---

# Dummy Key Management

Dummy-key registry: `src/modules/dummy-keys.json`, validated against `src/modules/dummy-keys.schema.json`.

## Policy

- Any dummy/placeholder API-key literal of the form `sk-` followed by 4+ alphanumerics hardcoded in a tracked config must resolve to a registered `dummyKeys.<name>.value`.
- New entries need three fields: `value` (the exact literal consumers use), `consumers` (repo-relative paths of configs using it), and `note` (why it exists).
- Consumers must use the registry `value` verbatim.
- Check step 14 (`run_dummy_key_uniformity` in `src/scripts/checks/check-steps/14-repository-policy.sh` / `.ps1`) enforces registration; keep the check in sync with registry shape changes.
