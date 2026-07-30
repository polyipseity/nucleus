---
description: "Use when maintaining shell scripts and Nix activation strings in the nucleus repo. Covers inlining, extraction to shared libs, and Nix build-time prepend patterns."
name: "Script Simplification Patterns"
applyTo: "src/scripts/**/*.sh, src/modules/**/*.nix, src/hosts/**/*.nix"
---

## Script simplification patterns

Apply these patterns when maintaining scripts under `src/scripts/`:

- **Tiny libs (<20 lines, single caller)**: When a lib file provides only 1-2 variable definitions or one small function used by a single caller, inline the content directly into the caller and delete the lib file.
- **Trivial scripts (<10 lines, simple if/command check)**: Inline into the parent Nix activation string via `${builtins.readFile ...}` instead of maintaining a separate file.
- **Console user boilerplate (MacBook scripts)**: When multiple scripts independently probe `/dev/console` for UID/username, extract into a shared function under `src/scripts/lib/macos-console-user.sh`.
- **Service script helper duplication**: When two daemon scripts define identical small functions (e.g., `require_command`), extract to `src/scripts/lib/require-command.sh` and prepend at Nix build time.
- **Shared symlink convergence logic**: When scripts share structural overlap (iterate find results → remove stale → create missing), extract into `src/scripts/lib/symlink-convergence.sh`.
- **Nix prepend pattern**: For scripts built via `pkgs.writeShellScript` or activation strings, prepend lib content at build time: `(builtins.readFile ../scripts/lib/foo.sh) + (builtins.readFile ../scripts/main-script.sh)` — avoids runtime sourcing path dependency.
