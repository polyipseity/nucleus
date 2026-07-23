# extraEnv → CLI args refactoring (Jul 2026)

Converted all `extraEnv` usages in `writeNucleusShellApplication` calls to either `ProgramArguments` (launchd agents) or `text` mode (CLI wrappers without natural callers).

Pattern summary:
- **Type A** (scripts sourcing libs via SCRIPT_DIR): keep `bundleDefault=true`, pass values as positional args in `ProgramArguments`/`ExecStart`
- **Type B** (scripts without lib sourcing): use `text` mode with hardcoded values
- **Category 2** (writeTextFile → writeNucleusShellApplication): extract to script in `src/scripts/services/` as import wrapper
- **Category 3** (non-convertible readFile): document and leave as-is

Commits (src/):
1. `09ee558a` refactor(camilladsp): pass WS_PORT as --port CLI arg
2. `d6678a46` refactor(daemons): convert extraEnv for https-proxy, linux-builder, jellyfin
3. `4185b1a3` refactor(litellm): convert extraEnv to CLI args for litellm-daemon
4. `00e7806b` refactor(macos): pass launchd agent values as ProgramArguments
5. `2aa7867e` refactor: remove extraEnv from open-manual and gc-managed-user-preferences
6. `7b7d7dce` refactor(nixos): convert open-manual and gs-pdf-opt wrappers to text mode
7. `1cabad05` refactor(icloud): convert icloud-exclusions to writeNucleusShellApplication
8. `389ba3e6` docs(nix-authoring): document CLI-arg-first pattern, deprecate extraEnv
