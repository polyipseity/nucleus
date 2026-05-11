---
description: "Use when authoring or modifying modules that interact with user-specific configuration. Explains the distinction between SOPS-aware primary user checks and hardcoded primary user logic for agent/feature provisioning."
name: "Primary User Distinction"
applyTo: "src/**/*.nix, src/**/*.ps1"
---

# Primary User Distinction

This repository manages configurations for multiple potential users, but most features are implemented only for the primary user "polyipseity". However, **secrets and SOPS decryption must remain multi-user aware** to preserve the option for future user additions.

## Rule Summary

- **SOPS/Secrets provisioning** (src/modules/secrets.nix): Check `isPrimaryUser = config.home.username == primaryUsername`
- **All other modules** (agents, AI, dev-repos, shell, etc.): Hardcode "polyipseity" as the target user
- **Exception**: dev-repos supports multi-user via per-user registry configuration; use current username but respect user registry settings

## Detailed Guidance

### When to Use isPrimaryUser Check

Use `isPrimaryUser` only in `src/modules/secrets.nix` for:
- SOPS secret decryption and materialization
- GPG key imports
- SSH key adoption
- Secret verification

Example:
```nix
lib.mkIf isPrimaryUser {
  # Secret materialization for the primary user only
}
```

**Why**: SOPS must remain isolated to the registered primary user (currently "polyipseity") so that future non-primary users do not trigger secret decryption or have access to secret files.

### When to Hardcode "polyipseity"

Use hardcoded `"polyipseity"` check in modules that implement features available only to the primary user:
- AI model provisioning (src/modules/ai/default.nix)
- Agent configuration (src/modules/agents.nix)
- ClawHub skill syncing
- Developer workspace setup
- VS Code configuration and extensions

**Important**: Even when using hardcoded checks, always read the feature configuration from the **centralized user registry** (flake.nix users.<username>). Only the primary user ("polyipseity") has these features enabled in the registry.

Example:
```nix
# In agents.nix:
agentsConfig = users.${currentUsername}.agents or { enable = false; };

lib.mkIf (config.home.username == "polyipseity" && agentsConfig.enable) {
  # Read polyipseity's agents config from the registry, then apply it
}
```

**Why**: This pattern ensures that if a future primary user is added, the feature infrastructure automatically flows through the registry without code changes. The hardcoded check is just a safety gate.

### Multi-User Aware Modules

Modules that are designed to support multiple users:
- `src/modules/dev-repos.nix` — reads per-user devRepos config from the user registry
- `src/modules/home.nix` — uses effectiveUsername to apply common settings to any user
- `src/modules/shell.nix` — applies shell aliases and env to any user

These modules should:
- Use `config.home.username` or `effectiveUsername` for dynamic user references
- Respect per-user configuration from the user registry (flake.nix users.<username>)
- NOT hardcode usernames (except in comments explaining the constraint)

## Verification Checklist

Before committing changes that affect users:

1. **Secrets/SOPS changes**: Confirm `isPrimaryUser` guard is in place in secrets.nix
2. **Feature provisioning changes**: Confirm hardcoded `"polyipseity"` comparison or document why multi-user support is intentional
3. **Dev-repos changes**: Confirm current username is used, but respects registry config
4. **Global modules (home.nix, shell.nix)**: Confirm they use dynamic username, not hardcoded values

## Common Patterns

### Pattern 1: Primary-User-Only Feature (Registry-Driven + Hardcoded Guard)
```nix
# In agents.nix:
agentsConfig = users.${currentUsername}.agents or { enable = false; };

lib.mkIf (config.home.username == "polyipseity" && agentsConfig.enable) {
  # Read from registry, guard with hardcoded check
  nucleus.agents.enable = true;
  ...
}
```

**Explanation**: Always read from the registry first. The hardcoded `"polyipseity"` check is a safety gate that prevents accidental feature activation for non-primary users.

### Pattern 2: Multi-User Feature (Registry-Driven)
```nix
# In dev-repos.nix:
userConfig = users.${currentUsername}.devRepos or {
  enable = false;
  ...
};
# Each user's devRepos is read from the registry; activation auto-routes to the correct user
```

### Pattern 3: Secrets (Primary User Only, SOPS-Aware)
```nix
# In secrets.nix:
isPrimaryUser = config.home.username == primaryUsername;
lib.mkIf isPrimaryUser {
  # Only the primary user receives decrypted secrets
}
```

## Notes

- The primary username ("polyipseity") is derived from the user registry in flake.nix by filtering for `isPrimary = true`
- If a new primary user is added to the registry, update all hardcoded primary-user-only features to use a new mechanism (e.g., a derived variable) rather than a string literal
- This distinction allows clean separation between multi-user infrastructure (secrets, shell, home) and primary-user applications (agents, AI, workspace tools)

## CI Checking Workflow

When checking GitHub Actions CI status:
- **Always use `gh cli`** instead of opening the web interface
- Commands: `gh run list --limit N`, `gh run view <run-id> --log-failed`, `gh run view <run-id> --json status,conclusion`
- This is faster, scriptable, and keeps the development workflow terminal-native
