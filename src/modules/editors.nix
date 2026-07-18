# Cross-platform editor configuration and VS Code extensions.
# Extension backend: nixpkgs on Linux vs Homebrew/nixpkgs on macOS;
# extensions managed by vsCodeExtensionBridge on all backends.
{
  lib,
  managedUser ? null,
  managedUsername ? null,
  pkgs,
  username ? null,
  users ? null,
  vsCodeMarketplace,
  ...
}:
let
  # Capture NUCLEUS_REPO_ROOT at eval time as fallback for home-manager activation,
  # which runs as the user and does not inherit the sudo-level env var.
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Platform switch used to keep one declarative config while selecting the
  # backend that integrates best on each OS.
  isDarwin = pkgs.stdenv.isDarwin;

  # Safe accessor for VS Code Marketplace extensions provided by
  # nix-vscode-extensions.  Returns a single-element list when the extension is
  # indexed, or an empty list with a trace warning when absent (e.g. for very
  # recently published extensions not yet in the index snapshot).  The list
  # wrapper lets callers use this in builtins.concatLists without special-casing.
  mkMktx =
    pub: name:
    let
      pubAttrs = vsCodeMarketplace.${pub} or { };
    in
    if pubAttrs ? ${name} then
      [ pubAttrs.${name} ]
    else
      builtins.trace "VS Code: ${pub}.${name} not in marketplace index — skipping" [ ];

  # Canonical extension set shared by both platforms, sorted alphabetically by
  # publisher.name.  44 extensions come from nixpkgs; 22 come from the VS Code
  # Marketplace via nix-vscode-extensions (via mkMktx).  A missing marketplace
  # entry degrades gracefully to an empty contribution rather than failing eval.
  # On all platforms, vsCodeExtensionBridge symlinks each extension into the
  # writable ~/.vscode/extensions and ~/.vscode-insiders/extensions directories
  # so both stable and insiders channels share an identical extension payload.
  sharedExtensions = builtins.concatLists [
    # asvetliakov
    (mkMktx "asvetliakov" "vscode-neovim")
    # arrterian
    (mkMktx "arrterian" "nix-env-selector")
    # astral-sh
    (mkMktx "astral-sh" "ty")
    # charliermarsh
    [ pkgs.vscode-extensions.charliermarsh.ruff ]
    # christian-kohler
    [ pkgs.vscode-extensions.christian-kohler.npm-intellisense ]
    [ pkgs.vscode-extensions.christian-kohler.path-intellisense ]
    # cl
    (mkMktx "cl" "eide")
    # cschlosser
    (mkMktx "cschlosser" "doxdocgen")
    # davidanson
    [ pkgs.vscode-extensions.davidanson.vscode-markdownlint ]
    # dbaeumer
    [ pkgs.vscode-extensions.dbaeumer.vscode-eslint ]
    # docker
    [ pkgs.vscode-extensions.docker.docker ]
    # editorconfig
    [ pkgs.vscode-extensions.editorconfig.editorconfig ]
    # esbenp
    [ pkgs.vscode-extensions.esbenp.prettier-vscode ]
    # github
    [ pkgs.vscode-extensions.github.codespaces ]
    (mkMktx "github" "remotehub")
    [ pkgs.vscode-extensions.github.vscode-github-actions ]
    # heaths
    (mkMktx "heaths" "vscode-guid")
    # ibm
    [ pkgs.vscode-extensions.ibm.output-colorizer ]
    # icrawl
    (mkMktx "icrawl" "discord-vscode")
    # james-yu
    [ pkgs.vscode-extensions.james-yu.latex-workshop ]
    # jnoortheen
    [ pkgs.vscode-extensions.jnoortheen.nix-ide ]
    # keroc
    (mkMktx "keroc" "hex-fmt")
    # mark-hansen
    (mkMktx "mark-hansen" "hledger-vscode")
    # mkhl
    (mkMktx "mkhl" "direnv")
    # ms-azuretools
    [ pkgs.vscode-extensions.ms-azuretools.vscode-containers ]
    [ pkgs.vscode-extensions.ms-azuretools.vscode-docker ]
    # ms-ceintl
    [ pkgs.vscode-extensions.ms-ceintl.vscode-language-pack-zh-hant ]
    # ms-python
    [ pkgs.vscode-extensions.ms-python.debugpy ]
    [ pkgs.vscode-extensions.ms-python.python ]
    (mkMktx "ms-python" "vscode-python-envs")
    # ms-toolsai
    [ pkgs.vscode-extensions.ms-toolsai.datawrangler ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter-keymap ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter-renderers ]
    [ pkgs.vscode-extensions.ms-toolsai.vscode-jupyter-cell-tags ]
    [ pkgs.vscode-extensions.ms-toolsai.vscode-jupyter-slideshow ]
    # ms-vscode-remote
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-containers ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-ssh ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-ssh-edit ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-wsl ]
    # ms-vscode
    [ pkgs.vscode-extensions.ms-vscode.cmake-tools ]
    (mkMktx "ms-vscode" "cpp-devtools")
    [ pkgs.vscode-extensions.ms-vscode.cpptools ]
    [ pkgs.vscode-extensions.ms-vscode.cpptools-extension-pack ]
    (mkMktx "ms-vscode" "cpptools-themes")
    [ pkgs.vscode-extensions.ms-vscode.hexeditor ]
    [ pkgs.vscode-extensions.ms-vscode.makefile-tools ]
    [ pkgs.vscode-extensions.ms-vscode.powershell ]
    [ pkgs.vscode-extensions.ms-vscode.remote-explorer ]
    (mkMktx "ms-vscode" "remote-repositories")
    (mkMktx "ms-vscode" "remote-server")
    (mkMktx "ms-vscode" "vscode-chat-customizations-evaluations")
    (mkMktx "ms-vscode" "vscode-serial-monitor")
    # ms-vsliveshare
    [ pkgs.vscode-extensions.ms-vsliveshare.vsliveshare ]
    # myriad-dreamin (stable only — pre-release builds have caused editor crashes)
    [ pkgs.vscode-extensions.myriad-dreamin.tinymist ]
    # redhat
    [ pkgs.vscode-extensions.redhat.vscode-yaml ]
    # rust-lang
    [ pkgs.vscode-extensions.rust-lang.rust-analyzer ]
    # s-nlf-fh
    (mkMktx "s-nlf-fh" "glassit")
    # sjhuangx
    (mkMktx "sjhuangx" "vscode-scheme")
    # sst-dev
    (mkMktx "sst-dev" "opencode-v2")
    # streetsidesoftware
    [ pkgs.vscode-extensions.streetsidesoftware.code-spell-checker ]
    # svelte
    [ pkgs.vscode-extensions.svelte.svelte-vscode ]
    # takumii
    (mkMktx "takumii" "markdowntable")
    # tamasfe
    [ pkgs.vscode-extensions.tamasfe.even-better-toml ]
    # tweag
    (mkMktx "tweag" "vscode-nickel")
    # vadimcn
    [ pkgs.vscode-extensions.vadimcn.vscode-lldb ]
  ];

  # Materialize the extension list under a deterministic Nix-store directory so
  # all VS Code app bundles (both stable and insiders, Homebrew or nixpkgs) can
  # consume the exact same extension payload via per-extension symlinks in the
  # vsCodeExtensionBridge activation.
  extensionStore = pkgs.symlinkJoin {
    name = "vscode-extensions";
    paths = sharedExtensions;
  };

  # Per-channel User data directories referenced by the vsCodeSymlinks activation.
  # These are shell strings whose $HOME is intentionally left unexpanded so the
  # activation script evaluates them at runtime with the actual home directory.
  stableBaseDir =
    if isDarwin then "$HOME/Library/Application Support/Code/User" else "$HOME/.config/Code/User";

  insidersBaseDir =
    if isDarwin then
      "$HOME/Library/Application Support/Code - Insiders/User"
    else
      "$HOME/.config/Code - Insiders/User";

  # Select the per-host keybindings source file so that platform-specific
  # shortcuts (Cmd on macOS vs Ctrl on NixOS/Linux) are tracked independently
  # without cross-host pollution in a shared repo file.
  # Method 1 (writable symlink): repo changes take effect without rebuild.
  vsCodeKeybindingsFile = if isDarwin then "keybindings.mac.json" else "keybindings.nixos.json";

  # Select the per-host Copilot chat model list so that each machine only
  # surfaces the Ollama models that fit within its VRAM budget.
  # mac: gemma4:e4b + qwen3:14b (24 GB unified memory allows both).
  # nixos/other: qwen3:8b only (discrete GPU capped at 6 GB VRAM).
  # Method 1 (writable symlink): repo changes take effect without rebuild.
  vsCodeChatLanguageModelsFile = # Method 1 (writable symlink)
    if isDarwin then "chatLanguageModels.mac.json" else "chatLanguageModels.nixos.json";

  # Python script that inserts a workspace trust entry for ~/dev into VS Code's
  # SQLite state database (globalStorage/state.vscdb) for both stable and
  # insiders channels.  pkgs.writeText is used instead of a shell heredoc to
  # avoid the column-0 delimiter constraint imposed by Nix ''...'' indentation
  # stripping; Nix strips the 4-space common prefix automatically, yielding
  # valid zero-indented Python.
  #
  # The script is non-fatal: a locked or absent DB produces a warning on stderr
  # so that a running VS Code instance or a fresh install (never launched) does
  # not break the activation chain.
  #
  # The script exits immediately when ~/dev does not yet exist (no-op for
  # edge cases such as a first-run race before provisionDevDirectory completes).
  vsCodeWorkspaceTrustPy = pkgs.writeText "vscode-workspace-trust.py" ''
    import json
    import os
    import sqlite3
    import sys

    HOME = os.environ.get("HOME", "")
    dev_path = os.path.join(HOME, "dev")

    # Only trust the dev directory when it actually exists on this machine.
    # Exits immediately when ~/dev is absent (edge case: first-run race before
    # provisionDevDirectory completes; resolved on the next apply).
    if not os.path.isdir(dev_path):
        sys.exit(0)

    trust_entry = {
        "uri": {"$mid": 1, "path": dev_path, "scheme": "file"},
        "trusted": True,
    }

    # Locate the state.vscdb for both stable and insiders channels.
    # The per-channel globalStorage directory is the authoritative location
    # for VS Code APPLICATION-scope storage regardless of installation backend.
    if sys.platform == "darwin":
        app_support = os.path.join(HOME, "Library", "Application Support")
        db_paths = [
            os.path.join(app_support, "Code", "User", "globalStorage", "state.vscdb"),
            os.path.join(app_support, "Code - Insiders", "User", "globalStorage", "state.vscdb"),
        ]
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
        db_paths = [
            os.path.join(config_home, "Code", "User", "globalStorage", "state.vscdb"),
            os.path.join(config_home, "Code - Insiders", "User", "globalStorage", "state.vscdb"),
        ]

    TRUST_KEY = "content.trust.model.key"

    for db_path in db_paths:
        if not os.path.isfile(db_path):
            continue
        try:
            # timeout=5 waits up to 5 s for a SQLite lock; if VS Code holds
            # the lock longer the OperationalError is caught below (non-fatal).
            conn = sqlite3.connect(db_path, timeout=5)
            try:
                cur = conn.cursor()
                cur.execute("SELECT value FROM ItemTable WHERE key = ?", (TRUST_KEY,))
                row = cur.fetchone()
                if row:
                    data = json.loads(row[0])
                    entries = data.get("uriTrustInfo", [])
                    already_trusted = any(
                        e.get("uri", {}).get("path") == dev_path
                        and e.get("uri", {}).get("scheme") == "file"
                        for e in entries
                    )
                    if already_trusted:
                        continue
                    entries.append(trust_entry)
                    data["uriTrustInfo"] = entries
                else:
                    data = {"uriTrustInfo": [trust_entry]}
                new_value = json.dumps(data, separators=(",", ":"))
                cur.execute(
                    "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
                    (TRUST_KEY, new_value),
                )
                conn.commit()
                print("vscode-trust: trusted", dev_path, "in", db_path, file=sys.stderr)
            finally:
                conn.close()
        except Exception as e:
            # Non-fatal: DB may be locked by a running VS Code instance, or
            # absent on a fresh install before VS Code has been launched once.
            print("vscode-trust: warning:", db_path, "-", e, file=sys.stderr)
  '';

  # Resolve the active managed user record so Neovim settings can follow the
  # same per-user override model used by other application configs.
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      "";

  effectiveUser =
    if managedUser != null then
      managedUser
    else if users != null && effectiveUsername != "" && builtins.hasAttr effectiveUsername users then
      users.${effectiveUsername}
    else
      { };

  # Utility: resolve app-scoped per-user settings overrides consistently.
  # This keeps the common `defaults // user.settings` pattern centralized.
  userAppSettings =
    appName:
    if
      builtins.hasAttr appName effectiveUser
      && builtins.isAttrs effectiveUser.${appName}
      && builtins.hasAttr "settings" effectiveUser.${appName}
      && builtins.isAttrs effectiveUser.${appName}.settings
    then
      effectiveUser.${appName}.settings
    else
      { };

  managedAppSettings = appName: defaults: defaults // (userAppSettings appName);

  # Neovim startup config is native init.lua (not a generated JSON/YAML format).
  # This default enables a targeted workaround for the upstream nvim/xterm.js
  # shifted-number regression in VS Code-family terminals and kitty-protocol
  # terminals where shifted digits can arrive as <S-1>…<S-0> keycodes.
  neovimDefaultSettings = {
    enableShiftNumberSymbolsWorkaround = true;
    shiftNumberTerminalPrograms = [
      "cursor"
      "kitty"
      "vscode"
    ];
  };

  neovimManagedSettings = managedAppSettings "neovim" neovimDefaultSettings;

  # Keep this map small and explicit; it targets US layout symbols produced by
  # shifted digits and only activates inside selected terminal hosts.
  shiftNumberMap = {
    "1" = "!";
    "2" = "@";
    "3" = "#";
    "4" = "$";
    "5" = "%";
    "6" = "^";
    "7" = "&";
    "8" = "*";
    "9" = "(";
    "0" = ")";
  };

  shiftNumberLuaTable = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (lhs: rhs: "  [${builtins.toJSON lhs}] = ${builtins.toJSON rhs},") shiftNumberMap
  );

  neovimTerminalProgramsLua = "{ ${builtins.concatStringsSep ", " (map builtins.toJSON neovimManagedSettings.shiftNumberTerminalPrograms)} }";

  neovimInitLua =
    builtins.replaceStrings
      [ "__ENABLE_WORKAROUND__" "__SHIFT_NUMBER_TERMINAL_PROGRAMS__" "__SHIFT_NUMBER_TABLE__" ]
      [
        (if neovimManagedSettings.enableShiftNumberSymbolsWorkaround then "true" else "false")
        neovimTerminalProgramsLua
        shiftNumberLuaTable
      ]
      (builtins.readFile ../scripts/configs/neovim-init.lua);
in
{
  programs.neovim = {
    enable = true;
    defaultEditor = true; # sets $EDITOR and $VISUAL to nvim
    # Pin explicit values to avoid version-gated default warnings and to adopt
    # the new Home Manager defaults intentionally.
    withPython3 = false;
    withRuby = false;
  };

  # Keep Neovim in native init.lua format and route managed defaults through a
  # single generated file so per-user overrides remain declarative.
  xdg.configFile."nvim/init.lua".text = neovimInitLua;

  # Keep VS Code binaries in nixpkgs on non-Darwin systems. On Darwin, package
  # installation backend is selected in core.nix and must not be duplicated
  # here, or backend overrides would diverge between modules.
  home.packages =
    lib.optionals (!isDarwin) [ pkgs.vscode ]
    ++ lib.optionals (!isDarwin && pkgs ? vscode-insiders) [ pkgs.vscode-insiders ];

  programs.vscode = {
    # Enable native Home Manager integration on non-Darwin hosts so the VS Code
    # binary is registered via the HM module.  On Darwin the backend is selected
    # in core.nix (Homebrew or nixpkgs) and must not be duplicated here.
    # Extension management is handled exclusively by vsCodeExtensionBridge on all
    # platforms; do not add extensions here to avoid a dual-manager conflict where
    # both HM and the bridge simultaneously write to ~/.vscode/extensions.
    enable = !isDarwin;
    package = pkgs.vscode;
  };

  home.activation = {
    # -------------------------------------------------------------------------
    # vsCodeSymlinks
    # Method 1 (writable symlink) — repo changes take effect without rebuild.
    # Replaces VS Code's per-channel config files with symlinks into the live
    # repo tree (src/modules/configs/vscode/) so that every VS Code write
    # (settings change, keybinding edit, MCP server addition, Copilot memory)
    # appears immediately as an unstaged git diff.
    #
    # Files managed: settings.json, keybindings.<host>.json (linked as
    #   keybindings.json), chatLanguageModels.<host>.json (merge-copied as
    #   chatLanguageModels.json), mcp.json, tasks.json.
    # Directories managed: snippets/, prompts/, profiles/,
    #   and globalStorage/github.copilot-chat/memory-tool/memories/
    #   (aliased in the repo as copilot-memories/).
    #
    # Both stable (Code) and insiders (Code - Insiders) channels are handled
    # so both app variants share the same repo-backed config.
    #
    # Migration safety:
    #   - Correct symlink     → no-op.
    #   - Wrong symlink       → remove, create correct symlink.  Handles the
    #                           transition from old home.file Nix-store symlinks.
    #   - Real non-empty file → copy to repo if repo target is absent/empty
    #                           (preserves local VS Code edits on first run),
    #                           then replace with symlink.
    #   - Real non-empty dir  → copy each file from it to the repo dir when
    #                           the repo does not yet contain that filename
    #                           (no-clobber), then replace with symlink.
    #   - Absent              → create symlink (parent dirs created as needed).
    #
    # Repo root is resolved from $NUCLEUS_REPO_ROOT (set by apply.sh before invoking
    # darwin-rebuild / nixos-rebuild and forwarded through sudo).
    # -------------------------------------------------------------------------
    vsCodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu
      ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
      ${builtins.replaceStrings
        [
          "__REPO_ROOT__"
          "__VSCODE_STABLE_BASE_DIR__"
          "__VSCODE_INSIDERS_BASE_DIR__"
          "__VSCODE_KEYBINDINGS_FILE__"
          "__VSCODE_CHAT_LANGUAGE_MODELS_FILE__"
          "__JQ_BIN__"
        ]
        [
          repoRoot
          stableBaseDir
          insidersBaseDir
          vsCodeKeybindingsFile
          vsCodeChatLanguageModelsFile
          "${pkgs.jq}/bin/jq"
        ]
        (builtins.readFile ../scripts/lib/vscode-symlinks.sh)
      }
    '';

    # -----------------------------------------------------------------------
    # vsCodeExtensionBridge
    # Populates both ~/.vscode/extensions and ~/.vscode-insiders/extensions
    # with per-extension symlinks into the Nix-managed extension store.  This
    # bridge runs unconditionally on ALL platforms (macOS and Linux) and for
    # BOTH channels (stable and insiders) so extension parity is guaranteed
    # regardless of the VS Code installation backend (Homebrew or nixpkgs).
    #
    # The directory must remain a real writable path rather than a symlink to
    # the Nix store because VS Code writes extensions.json inside it at startup;
    # a whole-directory store symlink would cause EACCES.  Instead, keep a real
    # writable directory and populate it with per-extension symlinks.
    # -----------------------------------------------------------------------
    vsCodeExtensionBridge = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu
      ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
      ${builtins.replaceStrings [ "__EXTENSION_STORE__" ] [ extensionStore ] (
        builtins.readFile ../scripts/lib/vscode-extension-bridge.sh
      )}
    '';

    # -----------------------------------------------------------------------
    # vsCodeWorkspaceTrust
    # Inserts a workspace trust entry for ~/dev into VS Code's SQLite state
    # database (globalStorage/state.vscdb) for both stable and insiders
    # channels so that the repository workspace opens without a trust prompt.
    #
    # VS Code workspace trust state lives in the SQLite DB, not in
    # settings.json; the settings.json keys only control the trust UI
    # (banner, startup prompt, empty-window behavior) and cannot pre-trust a
    # specific folder.  The DB is written directly via Python's built-in
    # sqlite3 module to avoid adding a heavyweight dependency.
    #
    # The activation is non-fatal when the DB is absent (VS Code not yet
    # launched once) or locked (VS Code currently running); both conditions
    # produce a warning to stderr so the operator is informed but the
    # activation chain is not interrupted.
    #
    # The Python script exits immediately when ~/dev is absent (edge case:
    # first-run race before provisionDevDirectory completes).
    # -----------------------------------------------------------------------
    vsCodeWorkspaceTrust = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -eu
      ${pkgs.python3}/bin/python3 '${vsCodeWorkspaceTrustPy}'
    '';
  };
}
