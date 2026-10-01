# Cross-platform editor configuration and VS Code extensions.
{
  config,
  lib,
  hostName,
  managedUser ? null,
  managedUsername ? null,
  pkgs,
  repoRoot,
  username ? null,
  users ? null,
  vsCodeMarketplace,
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # An extension missing from the index snapshot degrades to empty with a trace
  # warning, so a new upstream publish cannot fail eval.
  mkMktx =
    pub: name:
    let
      pubAttrs = vsCodeMarketplace.${pub} or { };
    in
    if pubAttrs ? ${name} then
      [ pubAttrs.${name} ]
    else
      builtins.trace "VS Code: ${pub}.${name} not in marketplace index — skipping" [ ];

  # Canonical extension set shared by both platforms, sorted by publisher.name.
  sharedExtensions = builtins.concatLists [
    (mkMktx "asvetliakov" "vscode-neovim")
    (mkMktx "arrterian" "nix-env-selector")
    (mkMktx "astral-sh" "ty")
    [ pkgs.vscode-extensions.charliermarsh.ruff ]
    [ pkgs.vscode-extensions.christian-kohler.npm-intellisense ]
    [ pkgs.vscode-extensions.christian-kohler.path-intellisense ]
    (mkMktx "cl" "eide")
    (mkMktx "cschlosser" "doxdocgen")
    [ pkgs.vscode-extensions.davidanson.vscode-markdownlint ]
    [ pkgs.vscode-extensions.dbaeumer.vscode-eslint ]
    [ pkgs.vscode-extensions.docker.docker ]
    [ pkgs.vscode-extensions.editorconfig.editorconfig ]
    [ pkgs.vscode-extensions.esbenp.prettier-vscode ]
    [ pkgs.vscode-extensions.github.codespaces ]
    (mkMktx "github" "remotehub")
    [ pkgs.vscode-extensions.github.vscode-github-actions ]
    (mkMktx "heaths" "vscode-guid")
    [ pkgs.vscode-extensions.ibm.output-colorizer ]
    (mkMktx "icrawl" "discord-vscode")
    [ pkgs.vscode-extensions.james-yu.latex-workshop ]
    [ pkgs.vscode-extensions.jnoortheen.nix-ide ]
    (mkMktx "keroc" "hex-fmt")
    (mkMktx "mark-hansen" "hledger-vscode")
    (mkMktx "mkhl" "direnv")
    [ pkgs.vscode-extensions.ms-azuretools.vscode-containers ]
    [ pkgs.vscode-extensions.ms-ceintl.vscode-language-pack-zh-hant ]
    [ pkgs.vscode-extensions.ms-python.debugpy ]
    [ pkgs.vscode-extensions.ms-python.python ]
    (mkMktx "ms-python" "vscode-python-envs")
    [ pkgs.vscode-extensions.ms-toolsai.datawrangler ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter-keymap ]
    [ pkgs.vscode-extensions.ms-toolsai.jupyter-renderers ]
    [ pkgs.vscode-extensions.ms-toolsai.vscode-jupyter-cell-tags ]
    [ pkgs.vscode-extensions.ms-toolsai.vscode-jupyter-slideshow ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-containers ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-ssh ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-ssh-edit ]
    [ pkgs.vscode-extensions.ms-vscode-remote.remote-wsl ]
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
    [ pkgs.vscode-extensions.ms-vscode.vscode-speech ]
    [ pkgs.vscode-extensions.ms-vsliveshare.vsliveshare ]
    # myriad-dreamin, stable only: pre-release builds have crashed the editor
    [ pkgs.vscode-extensions.myriad-dreamin.tinymist ]
    [ pkgs.vscode-extensions.redhat.vscode-yaml ]
    [ pkgs.vscode-extensions.rust-lang.rust-analyzer ]
    (mkMktx "s-nlf-fh" "glassit")
    (mkMktx "sjhuangx" "vscode-scheme")
    (mkMktx "sst-dev" "opencode-v2")
    [ pkgs.vscode-extensions.streetsidesoftware.code-spell-checker ]
    [ pkgs.vscode-extensions.svelte.svelte-vscode ]
    (mkMktx "takumii" "markdowntable")
    [ pkgs.vscode-extensions.tamasfe.even-better-toml ]
    (mkMktx "tweag" "vscode-nickel")
    [ pkgs.vscode-extensions.vadimcn.vscode-lldb ]
  ];

  # One store directory so every channel and backend consumes the same payload.
  extensionStore = pkgs.symlinkJoin {
    name = "vscode-extensions";
    paths = sharedExtensions;
  };

  # $HOME stays unexpanded so the activation script resolves it at runtime.
  stableBaseDir =
    if isDarwin then "$HOME/Library/Application Support/Code/User" else "$HOME/.config/Code/User";

  insidersBaseDir =
    if isDarwin then
      "$HOME/Library/Application Support/Code - Insiders/User"
    else
      "$HOME/.config/Code - Insiders/User";

  # Per-host overlay files, same pattern as chatLanguageModels.
  vsCodeHostFile = name: "${name}.${hostName}.json";
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  vsCodeKeybindingsFile = vsCodeHostFile "keybindings";
  # check-suppress:config-method: method 3 (merge) -- name-keyed merge preserves VS Code-added model entries while refreshing repo entries.
  vsCodeChatLanguageModelsFile = vsCodeHostFile "chatLanguageModels";

  # Resolve the active managed user record so Neovim settings follow the same
  # per-user override model as other application configs.
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

  # Workaround for the upstream nvim/xterm.js shifted-number regression, where
  # shifted digits arrive as <S-1> to <S-0> keycodes in VS Code and kitty.
  neovimDefaultSettings = {
    enableShiftNumberSymbolsWorkaround = true;
    shiftNumberTerminalPrograms = [
      "cursor"
      "kitty"
      "vscode"
    ];
  };

  neovimManagedSettings = managedAppSettings "neovim" neovimDefaultSettings;

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
      (builtins.readFile ../scripts/editors/neovim-init.lua);

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  programs.neovim = {
    enable = true;
    defaultEditor = true; # sets $EDITOR and $VISUAL to nvim
    # Pinned to avoid version-gated default warnings.
    withPython3 = false;
    withRuby = false;
  };

  xdg.configFile."nvim/init.lua".text = neovimInitLua;

  # The Darwin backend is selected in core.nix, so it must not be duplicated here.
  home.packages =
    lib.optionals (!isDarwin) [ pkgs.vscode ]
    ++ lib.optionals (!isDarwin && pkgs ? vscode-insiders) [ pkgs.vscode-insiders ];

  programs.vscode = {
    # Extensions are managed only by symlink-vscode-extensions; adding them here
    # would give HM and the bridge two writers for ~/.vscode/extensions.
    enable = !isDarwin;
    package = pkgs.vscode;
  };

  programs.cursor =
    lib.mkIf (!isDarwin && (config.nucleus.packages.enabled.cursor or false) && pkgs ? code-cursor)
      {
        enable = true;
        package = pkgs.code-cursor;
      };

  home.activation = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    # VS Code writes land in the live repo tree as an unstaged diff.
    #
    # Symlink policy:
    #   - Correct symlink → no-op.
    #   - Wrong symlink → remove, create correct symlink.
    #   - Real file or directory at target path → fail; fix manually and re-apply.
    #   - Absent → create symlink (parent dirs created as needed).
    symlink-vscode-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/editors/symlink-vscode-config.sh" \
        "${repoRoot}" \
        "${effectiveUsername}" \
        "${stableBaseDir}" \
        "${insidersBaseDir}" \
        "${vsCodeKeybindingsFile}" \
        "${vsCodeChatLanguageModelsFile}" \
        "${pkgs.jq}/bin/jq"
    '';

    # VS Code writes extensions.json at startup, so the directory stays real and
    # writable; a whole-directory store symlink would give EACCES.
    symlink-vscode-extensions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/editors/bridge-vscode-extensions.sh" "${extensionStore}"
    '';

    # Same store and directory policy as the VS Code bridge.
    symlink-cursor-extensions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/editors/bridge-cursor-extensions.sh" "${extensionStore}"
    '';

    # -----------------------------------------------------------------------
    # Trust state lives in the SQLite DB, not settings.json: the settings keys
    # only control the trust UI and cannot pre-trust a folder. A missing or
    # locked DB warns instead of failing, so a first run does not break.
    trust-vscode-workspace = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/editors/trust-vscode-workspace.sh" "${pkgs.python3}/bin/python3"
    '';

    # Shares trust-paths.json with trust-vscode-workspace so both trust the
    # same directories.
    trust-pi-project = lib.hm.dag.entryAfter [ "trust-vscode-workspace" ] ''
      "${activationBundle}/src/scripts/editors/trust-pi-project.sh" "${pkgs.python3}/bin/python3"
    '';
  };
}
