# modules/editors.nix — Cross-platform editor configuration and VS Code symmetry.
#
# Source of truth for VS Code extensions and config wiring lives here.
# Installation backend intentionally pivots by platform:
#   • Linux/NixOS: nixpkgs binaries; extensions managed by vsCodeExtensionBridge.
#   • macOS: backend selected in modules/core.nix (Homebrew or nixpkgs);
#     extensions managed by vsCodeExtensionBridge on all backends.
#
# The full 65-extension baseline is built entirely from Nix derivations:
#   • 43 extensions packaged directly in nixpkgs (pkgs.vscode-extensions).
#   • 22 extensions sourced from the VS Code Marketplace via the
#     nix-vscode-extensions flake input (vsCodeMarketplace extraSpecialArg).
#
# VS Code config files (settings, per-host keybindings, MCP, tasks, snippets,
# prompts, profiles, and Copilot Chat memory) are kept as live repo files under
# src/modules/configs/vscode/ so that every VS Code write appears as an
# unstaged git change.  The vsCodeSymlinks activation creates symlinks from
# the per-channel User/ directories to those repo files at apply time.
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
    name = "nucleus-vscode-extensions";
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
  vsCodeKeybindingsFile = if isDarwin then "keybindings.mac.json" else "keybindings.nixos.json";

  # Select the per-host Copilot chat model list so that each machine only
  # surfaces the Ollama models that fit within its VRAM budget.
  # mac: gemma4:e4b + qwen3:14b (24 GB unified memory allows both).
  # nixos/other: qwen3:8b only (discrete GPU capped at 6 GB VRAM).
  vsCodeChatLanguageModelsFile =
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
  # shifted-number regression in VS Code-family terminals.
  neovimDefaultSettings = {
    enableShiftNumberSymbolsWorkaround = true;
    shiftNumberTerminalPrograms = [
      "vscode"
      "cursor"
    ];
  };

  neovimManagedSettings = managedAppSettings "neovim" neovimDefaultSettings;

  # Keep this map small and explicit; it targets US layout symbols produced by
  # shifted digits and only activates inside selected terminal hosts.
  shiftNumberMap = {
    "!" = "1";
    "@" = "2";
    "#" = "3";
    "$" = "4";
    "%" = "5";
    "^" = "6";
    "&" = "7";
    "*" = "8";
    "(" = "9";
    ")" = "0";
  };

  shiftNumberLuaTable = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (lhs: rhs: "  [${builtins.toJSON lhs}] = ${builtins.toJSON rhs},") shiftNumberMap
  );

  neovimInitLua = ''
        -- Managed by Home Manager (nucleus): src/modules/editors.nix
        -- Neovim supports native Lua config in init.lua (or Vimscript init.vim).
        -- Keep init.lua as the canonical managed format here.

        local managed = {
          enable_shift_number_symbols_workaround = ${
            if neovimManagedSettings.enableShiftNumberSymbolsWorkaround then "true" else "false"
          },
          shift_number_terminal_programs = ${builtins.toJSON neovimManagedSettings.shiftNumberTerminalPrograms},
        }

        if managed.enable_shift_number_symbols_workaround then
          local terminal_program = (vim.env.TERM_PROGRAM or ""):lower()
          local should_apply = false

          for _, candidate in ipairs(managed.shift_number_terminal_programs or {}) do
            if terminal_program == tostring(candidate):lower() then
              should_apply = true
              break
            end
          end

          if should_apply then
            local shifted_digits = {
    ${shiftNumberLuaTable}
            }

            for lhs, rhs in pairs(shifted_digits) do
              vim.keymap.set({ "i", "n", "x" }, lhs, rhs, {
                desc = "workaround: xterm shifted-number regression",
                noremap = true,
                silent = true,
              })
              vim.keymap.set("c", lhs, function()
                return rhs
              end, {
                expr = true,
                noremap = true,
              })
            end
          end
        end
  '';
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
    # Replaces VS Code's per-channel config files with symlinks into the live
    # repo tree (src/modules/configs/vscode/) so that every VS Code write
    # (settings change, keybinding edit, MCP server addition, Copilot memory)
    # appears immediately as an unstaged git diff.
    #
    # Files managed: settings.json, keybindings.<host>.json (linked as
    #   keybindings.json), chatLanguageModels.<host>.json (linked as
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
    # Repo root is read from ~/.config/nucleus/repo-root (written by apply.sh
    # before invoking darwin-rebuild / nixos-rebuild), with $NUCLEUS_REPO as
    # an optional override for manual runs outside of apply.sh.
    # -------------------------------------------------------------------------
    vsCodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      # Locate the live repo checkout so the activation can resolve the
      # src/modules/configs/vscode/ path regardless of where the repo lives.
      # apply.sh writes REPO_ROOT to this file before the rebuild because
      # environment variables do not reliably survive the sudo boundary that
      # darwin-rebuild and nixos-rebuild cross.
      _vsym_repo_root_file="$HOME/.config/nucleus/repo-root"
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _vsym_repo_root="$NUCLEUS_REPO"
      elif [ -f "$_vsym_repo_root_file" ]; then
        _vsym_repo_root="$(cat "$_vsym_repo_root_file")"
      else
        echo "VS Code: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _vsym_config_dir="$_vsym_repo_root/src/modules/configs/vscode"
      if [ ! -d "$_vsym_config_dir" ]; then
        echo "VS Code: config dir not found: $_vsym_config_dir" >&2
        exit 1
      fi

      # ensure_file_symlink TARGET LINK
      # Creates LINK as a symlink pointing to TARGET (a file).
      ensure_file_symlink() {
        _efs_target="$1"
        _efs_link="$2"

        if [ -L "$_efs_link" ]; then
          # Already a symlink: skip when correct, remove when wrong (e.g. old
          # Nix-store path left over after removing home.file entry).
          [ "$(readlink "$_efs_link")" = "$_efs_target" ] && return 0
          rm "$_efs_link"
        elif [ -f "$_efs_link" ]; then
          # Real file: migrate content to repo target only when the repo does
          # not already contain meaningful content, so local VS Code edits that
          # pre-date this activation are not silently discarded.
          if [ ! -s "$_efs_target" ]; then
            cp "$_efs_link" "$_efs_target"
          fi
          rm "$_efs_link"
        fi

        mkdir -p "$(dirname "$_efs_link")"
        ln -s "$_efs_target" "$_efs_link"
      }

      # ensure_dir_symlink TARGET LINK
      # Creates LINK as a symlink pointing to TARGET (a directory).
      ensure_dir_symlink() {
        _eds_target="$1"
        _eds_link="$2"

        if [ -L "$_eds_link" ]; then
          [ "$(readlink "$_eds_link")" = "$_eds_target" ] && return 0
          rm "$_eds_link"
        elif [ -d "$_eds_link" ]; then
          # Real directory: copy each top-level file to the repo dir without
          # overwriting existing repo content (repo is the source of truth).
          find "$_eds_link" -maxdepth 1 -mindepth 1 -type f | while IFS= read -r _f; do
            _fname="$(basename "$_f")"
            if [ ! -e "$_eds_target/$_fname" ]; then
              cp "$_f" "$_eds_target/$_fname"
            fi
          done
          rm -rf "$_eds_link"
        fi

        mkdir -p "$(dirname "$_eds_link")"
        ln -s "$_eds_target" "$_eds_link"
      }

      for _vsym_base_dir in "${stableBaseDir}" "${insidersBaseDir}"; do
        ensure_file_symlink "$_vsym_config_dir/settings.json"    "$_vsym_base_dir/settings.json"
        ensure_file_symlink "$_vsym_config_dir/${vsCodeKeybindingsFile}" "$_vsym_base_dir/keybindings.json"
        ensure_file_symlink "$_vsym_config_dir/${vsCodeChatLanguageModelsFile}" "$_vsym_base_dir/chatLanguageModels.json"
        ensure_file_symlink "$_vsym_config_dir/mcp.json"         "$_vsym_base_dir/mcp.json"
        ensure_file_symlink "$_vsym_config_dir/tasks.json"       "$_vsym_base_dir/tasks.json"
        ensure_dir_symlink  "$_vsym_config_dir/snippets"         "$_vsym_base_dir/snippets"
        ensure_dir_symlink  "$_vsym_config_dir/prompts"          "$_vsym_base_dir/prompts"
        ensure_dir_symlink  "$_vsym_config_dir/profiles"         "$_vsym_base_dir/profiles"
        # Copilot Chat stores memories under a deep per-extension subpath;
        # the repo uses a flat alias so the directory is easy to navigate.
        ensure_dir_symlink  "$_vsym_config_dir/copilot-memories" \
          "$_vsym_base_dir/globalStorage/github.copilot-chat/memory-tool/memories"
      done
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

      source_extensions='${extensionStore}/share/vscode/extensions'
      stable_extensions="$HOME/.vscode/extensions"
      insiders_extensions="$HOME/.vscode-insiders/extensions"

      # setup_extension_dir CHANNEL_EXTENSIONS
      # Ensures CHANNEL_EXTENSIONS is a real writable directory containing
      # per-extension symlinks into the Nix-managed source tree.  VS Code must
      # write extensions.json inside this directory; a whole-directory symlink
      # to the immutable Nix store prevents that with EACCES.
      #
      # Algorithm:
      #   1. Migrate the old whole-directory Nix-store symlink (if present) to
      #      a real writable directory so VS Code can write files inside it.
      #   2. Add a per-extension symlink for every entry under source_extensions.
      #      Correct symlinks → no-op; wrong symlinks → replaced; non-symlinks
      #      (user-installed extensions) → left untouched.
      #   3. Prune all entries not in the Nix-managed extension set (both stale
      #      symlinks and non-managed real directories/files) and remove
      #      .obsolete (VS Code deferred-deletion dotfile).
      #   4. Remove extensions.json so VS Code rescans the directory on next
      #      invocation.  When absent, VS Code derives the manifest from the
      #      directory; when present it trusts the file and skips the scan.
      setup_extension_dir() {
        _sed_dir="$1"

        # Step 1: migrate old whole-directory symlink to a real writable directory.
        # The previous approach linked the entire extensions/ dir to the Nix store,
        # which made VS Code's extensions.json writes fail with EACCES.
        if [ -L "$_sed_dir" ]; then
          rm "$_sed_dir"
        fi
        mkdir -p "$_sed_dir"

        # Step 2: add a per-extension symlink for each Nix-managed extension.
        # Trailing-slash glob only matches actual directories (and symlinked dirs);
        # the -d guard handles the empty-source no-op without error.
        for _sed_src in "$source_extensions"/*/; do
          [ -d "$_sed_src" ] || continue
          _sed_src="''${_sed_src%/}"
          _sed_ext_name="''${_sed_src##*/}"
          _sed_link="$_sed_dir/$_sed_ext_name"

          if [ -L "$_sed_link" ]; then
            # Correct symlink → no-op; wrong target (e.g. after store upgrade) → replace.
            [ "$(readlink "$_sed_link")" = "$_sed_src" ] && continue
            rm "$_sed_link"
          elif [ -e "$_sed_link" ]; then
            # Non-symlink entry (user-installed extension): leave untouched.
            continue
          fi

          ln -s "$_sed_src" "$_sed_link"
        done

        # Step 3: prune all entries not in the Nix-managed extension set.
        # Removes both stale symlinks and non-managed real directories/files so the
        # bridge is the sole source of truth for the directory contents.  Use a
        # bare-star glob (no trailing /) to catch broken symlinks as well.
        for _sed_existing in "$_sed_dir"/*; do
          [ -e "$_sed_existing" ] || [ -L "$_sed_existing" ] || continue
          _sed_ext_name="''${_sed_existing##*/}"
          [ -e "$source_extensions/$_sed_ext_name" ] && continue
          rm -rf "$_sed_existing"
        done
        # .obsolete is a VS Code deferred-deletion marker written as a dotfile
        # (not matched by the * glob above); remove it unconditionally so the
        # bridge fully owns the directory state.
        rm -f "$_sed_dir/.obsolete"

        # Step 4: remove extensions.json so VS Code rescans the directory on
        # next invocation and derives a fresh manifest from the symlink set.
        # VS Code creates this file from a directory scan when absent; when the
        # file is present VS Code trusts it and skips the scan, so a stale file
        # (e.g. from a previous apply with fewer managed extensions) would make
        # newly added extensions invisible.  The bridge owns the directory
        # state; extensions.json is a derived artifact, not a source of truth.
        rm -f "$_sed_dir/extensions.json"
      }

      mkdir -p "$HOME/.vscode"
      setup_extension_dir "$stable_extensions"

      mkdir -p "$HOME/.vscode-insiders"
      setup_extension_dir "$insiders_extensions"
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
