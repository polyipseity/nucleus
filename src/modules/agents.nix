# Declarative ~/.agents directory layout with per-entry symlinks into
# src/users/<username>/agents/ (skills/ managed by install-agent-skills).
# The repo root is baked at build time from $NUCLEUS_REPO_ROOT for out-of-store
# symlink sources and lib runtime-sourcing paths.
#
# Sandbox-runtime (srt) policy: srt is required for coding agents that lack
# built-in protections. Only `pi` runs inside srt, and the wrapper fails loudly
# when srt is missing. `pi-unrestricted` skips the sandbox and needs no srt; the
# long name is deliberate. vscode and cursor have their own protections.
#
# Settings: `~/.srt-settings.json` (method-1 writable symlink from
# `src/users/default/srt/settings.json`, per-user overridable).
{
  config,
  hostName,
  lib,
  pkgs,
  repoRoot,
  ...
}:
let
  effectiveUsername = config.home.username;
  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };
  clawhubManifestRelativePath = overlay.toRepoRelPath (
    overlay.selectFile "agents" "clawhub-skills.json"
  );

  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };

  # Mirrors pwsh.nix.
  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);

  # A missing manager or host key is a hard error: an empty set would make
  # zap-style convergence prune installed packages.
  packagesDesired = builtins.fromJSON (builtins.readFile ./packages/desired.json);
  desiredFor =
    manager:
    packagesDesired.${manager}.${hostName}
      or (throw "src/modules/packages/desired.json has no '${manager}' entry for host '${hostName}'");

  superpowersLockfile = lockfile.cursor.superpowers;
  superpowersSrc = builtins.fetchGit {
    url = superpowersLockfile.source;
    rev = superpowersLockfile.rev;
    submodules = false;
  };

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

in
{
  # WHY: OpenCode discovers global agents under ~/.config/opencode/agents and
  # global commands under ~/.config/opencode/commands, both bridged to the
  # shared agent-asset tree in ~/.agents/. linkGeneration rewrites these paths on
  # every apply, hence the unprotect/protect pairing around it.
  home.file = {
    ".config/opencode/agents".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/agents";
    ".config/opencode/commands".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/prompts";
  };

  home.activation.unprotect-opencode-symlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "unprotect" "agents.nix" "$HOME/.config/opencode/agents"
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "unprotect" "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation.protect-opencode-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "agents.nix" "$HOME/.config/opencode/agents"
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "agents.nix" "$HOME/.config/opencode/commands"
  '';

  # check-suppress:config-method: method 4 (activation script manages whole-directory symlinks) -- the agents/
  # config directory is deployed via symlink-agent-config.sh which creates per-entry
  # symlinks in ~/.agents/. No Nix-level deployment needed; the scripts read
  # directly from the repo tree at activation time.
  home.activation = {
    # Method-1 writable symlink so the plugin can be edited without a rebuild.
    # v2 loads a plugin directory with a `server.js` entrypoint (and optional
    # `tui.js`); seed the directory into both global plugin locations so config
    # and auto-discovery can find it.
    seed-opencode-notify-plugin = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/.opencode/plugins/harness-notify" \
        "${overlay.toRepoRelPath (overlay.selectFile "opencode" "plugins/harness-notify")}" \
        "${hostName}"
      mkdir -p "$HOME/.config/opencode/plugins"
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/.config/opencode/plugins/harness-notify" \
        "${overlay.toRepoRelPath (overlay.selectFile "opencode" "plugins/harness-notify")}" \
        "${hostName}"
    '';

    # Method-1 writable symlink for the prompt-tools v2 TUI plugin directory.
    seed-opencode-prompt-tools-plugin = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/.opencode/plugins/prompt-tools" \
        "${overlay.toRepoRelPath (overlay.selectFile "opencode" "plugins/prompt-tools")}" \
        "${hostName}"
      mkdir -p "$HOME/.config/opencode/plugins"
      "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
        "$HOME/.config/opencode/plugins/prompt-tools" \
        "${overlay.toRepoRelPath (overlay.selectFile "opencode" "plugins/prompt-tools")}" \
        "${hostName}"
    '';

    # skills/ is excluded because install-agent-skills manages it, so fetched
    # ClawHub downloads land in a real, untracked directory.
    symlink-agent-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/agents/symlink-agent-config.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # The skills/ tree is a real directory, so bundled per-skill symlinks can
    # coexist with fetched real dirs and ClawHub writes never land in the tracked
    # repo tree. A name collision with a fetched skill fails fast.
    install-agent-skills = lib.hm.dag.entryAfter [ "symlink-agent-config" ] ''
      "${activationBundle}/src/scripts/agents/install-agent-skills.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # Pi discovers skills natively from ~/.agents/skills/, so none is symlinked.
    #
    # Why after install-agent-skills: the extensions/ and pi-settings.json
    # entries come from symlink-agent-config.sh, which runs earlier.
    symlink-pi-agent-config = lib.hm.dag.entryAfter [ "install-agent-skills" ] ''
      "${activationBundle}/src/scripts/agents/symlink-pi-agent-config.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # Only packages absent from nixpkgs and cargo-binstall are managed here
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    #
    # Why the node-gyp toolchain args: allowlisted packages run lifecycle
    # scripts, and bun rebuilds a native dependency through node-gyp when it
    # cannot use the shipped prebuild. The activation PATH carries neither a
    # Python interpreter nor make, so gyp's find-python step would abort the
    # whole activation.
    install-bun-packages = lib.hm.dag.entryAfter [ "install-agent-skills" ] ''
      "${activationBundle}/src/scripts/packages/install-bun-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.bun}/bin/bun" \
        "${pkgs.gawk}/bin/awk" \
        "${pkgs.node-gyp}/bin/node-gyp" \
        "${pkgs.python3}/bin/python3" \
        "${pkgs.gnumake}/bin/make" \
        '${builtins.toJSON (desiredFor "bun")}'
    '';

    # Why after install-bun-packages: pi spawns the bare command "bun" for every
    # npm: install (npmCommand in src/users/default/pi/settings.json), so bun's
    # directory must be on the child PATH, not only callable by path.
    install-pi-packages = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/packages/install-pi-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.pi-coding-agent}/bin/pi" \
        "${pkgs.gawk}/bin/awk" \
        "${pkgs.gnused}/bin/sed" \
        '${builtins.toJSON (desiredFor "pi")}' \
        "${pkgs.bun}/bin"
    '';

    # Only tools absent from nixpkgs, cargo-binstall, and bun are managed here
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    install-uv-tools = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/packages/install-uv-tools.sh" \
        "${pkgs.uv}/bin/uv" \
        "${pkgs.gawk}/bin/awk" \
        "${pkgs.gnugrep}/bin/grep" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON (desiredFor "uv")}'
    '';

    # rustup default is none so rust-toolchain.toml stays authoritative.
    # Why after linkGeneration: must run before install-cargo-binstall-packages.
    init-rustup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/packages/init-rustup.sh" \
        "${pkgs.rustup}/bin/rustup" \
        "${pkgs.jq}/bin/jq"
    '';

    # Uses the nixpkgs cargo store path for list/uninstall; probing
    # ~/.cargo/bin at runtime is prohibited.
    #
    # Why after init-rustup: the stable toolchain backs cargo-binstall's
    # compilation fallback. Unified with Windows Invoke-RustupSetup and
    # Invoke-CargoBinstallSetup.
    install-cargo-binstall-packages = lib.hm.dag.entryAfter [ "init-rustup" ] ''
      "${activationBundle}/src/scripts/packages/install-cargo-binstall-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.gawk}/bin/awk" \
        '${builtins.toJSON (desiredFor "cargo-binstall")}' \
        "${pkgs.cargo}/bin/cargo" \
        "${pkgs.cargo-binstall}/bin/cargo-binstall" \
        "${pkgs.sccache}/bin/sccache"
    '';

    # Why after install-bun-packages: ClawHub arrives with it. Skill sync is
    # additive, so a missing skill is not a failed system state.
    sync-clawhub-skills = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/agents/sync-clawhub-skills.sh" \
        "${pkgs.jq}/bin/jq" \
        "${managedPaths.toShellPrependGuard}" \
        "${managedPaths.toShellAppendGuard}" \
        "${clawhubManifestRelativePath}" \
        "$HOME/${builtins.elemAt managedPaths.pathComponents.append 0}/clawhub"
    '';

    # builtins.fetchGit checks the pinned rev out into the store at build time;
    # activation only creates the symlink. A missing plugin is not a failed
    # system state.
    symlink-superpowers-plugin = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/agents/symlink-superpowers-plugin.sh" \
        "${superpowersSrc}"
    '';

    # Layered after the bundled skills, and after the plugin symlink so its
    # skills directory resolves.
    symlink-superpowers-skills =
      lib.hm.dag.entryAfter [ "install-agent-skills" "symlink-superpowers-plugin" ]
        ''
          "${activationBundle}/src/scripts/agents/install-agent-skills.sh" \
            "${repoRoot}" "${effectiveUsername}" \
            "${superpowersSrc}/skills"
        '';

    # OpenCode is not installed on every host, so this step is best-effort.
    symlink-superpowers-for-opencode =
      lib.hm.dag.entryAfter [ "linkGeneration" "symlink-superpowers-plugin" ]
        ''
          "${activationBundle}/src/scripts/agents/symlink-superpowers-for-opencode.sh"
        '';

  };
}
