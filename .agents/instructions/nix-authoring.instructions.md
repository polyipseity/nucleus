---
description: "Use when authoring or editing Nix files in src/."
name: "Nix Authoring"
applyTo: "src/**/*.nix, src/modules/**/*.nix, src/hosts/**/*.nix"
---

# Nix authoring

# Upstream workarounds registry: .agents/instructions/upstream-workarounds.instructions.md

Every flake input follows nixpkgs; keep `username` and system strings in the top `let`; `allowUnfree` only in `mkPkgs`; run `nix flake lock` from `src/` after input changes; no `builtins.fetchTarball` for pinned inputs. Every host imports `../../modules/core.nix`; POSIX hosts import `../../modules/posix` but not `posix/security.nix`, which NixOS imports directly. Keep drivers and kernel args in host files, `system.stateVersion` at bootstrap value, and real `hardware-configuration.nix` after first install.

Guard NixOS and `home.*` options with `lib.mkIf`; no module-level `with pkgs;`; `home.file` uses `lib.optionalAttrs` plus `builtins.pathExists`; defaults only when obvious. Every `.nix` file in a directory is `default.nix`, with no file beside a same-named directory (step 12).

Use `pkgs.writeNucleusShellApplication`, not `writeShellApplication`, except with `# WHY:`. `scriptName` is repo-relative without `.sh`; `text` for trivial bodies, `extraEnv` for shared sourced bodies, positional args otherwise. Activation blocks never source `src/scripts/lib/` directly; use wrappers and `builtins.readFile`, substitute `__UPPERCASE_WITH_DOUBLE_UNDERSCORES__` tokens, and keep tokens out of comments. Step 11 rejects bare external commands.

Extract real logic and runtime imperative work into scripts; keep Nix-expression loops and snippets under 10 lines inline. Libraries hold only definitions. nixpkgs has no Xcode shims, so use the managed `apple-sdk-*` modules. Validate with `nix-instantiate --parse`, `nix flake check`, and `scripts/gc.sh`/`.ps1` cleanup; use `--replace-fail`, not deprecated `--replace-warn`.

Details: `src/users/default/agents/skills/nucleus-platform-reference/references/nix-authoring.md`.
