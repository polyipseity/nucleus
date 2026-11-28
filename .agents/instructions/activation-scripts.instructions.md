---
description: "Use when adding, renaming, or reviewing activation entries or scripts."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh, src/modules/terminal-activations.nix, src/hosts/Windows/apply.ps1, src/platforms/Windows/modules/system/Sync-TerminalActivation.ps1"
---

# Activation scripts and naming

Activation keys (`home.activation.*`, `system.activationScripts.*`, `nucleus.terminalActivations.*`) are lowerCamelCase and verb-first, with a `macos`/`nixos` prefix when OS-specific and none when cross-platform. Never use `nucleus-`. Script filenames stay kebab-case. Exempt names are generated `config-utils.nix` names, listed Home Manager built-ins, upstream `hermesAgentSetup`, and `sops-nix`; no nucleus-owned key is exempt. `entryAfter`/`entryBefore` use exact keys from `src/modules/lib/activation-dag.nix`.

nix-darwin calls only `preActivation`, `extraActivation`, and `postActivation`; custom names are ignored. Each fragment carries an owning-module header. Bundle scripts through `src/modules/lib/script-tree.nix` (`$out/` is the repo root), invoke `"${activationBundle}/src/scripts/<path>.sh" <args>`, set `SCRIPT_DIR`, pass values as positional args, and use `lib.escapeShellArg` or `builtins.toJSON`.

Prohibited: `readFile` or `replaceStrings` in activation bodies (except inline pure blocks of at most 3 lines with no loops, conditionals, or tools), `+` concatenation in script-producing expressions, tokens in bundle scripts, `$REPO_ROOT` at runtime, wrapper-only sourcing scripts, and inline Python. Exceptions need inline `# WHY:`.

`nucleus.terminalActivations` needs TCC-sensitive terminal context, no alternative, and `# WHY: terminal-activations (last resort):`. Details: `src/users/default/agents/skills/nucleus-platform-reference/references/activation-scripts.md`.
