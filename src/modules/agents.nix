# Declarative ~/.agents directory layout with per-entry symlinks into
# src/users/<username>/agents/ (skills/ managed by install-agent-skills).
# The repo root is baked at build time from $NUCLEUS_REPO_ROOT for out-of-store
# symlink sources and lib runtime-sourcing paths.
#
# ## Sandbox-runtime (srt) policy
#
# srt is a hard requirement for coding agents that lack built-in protections.
# Currently only `pi` runs inside srt for filesystem and network isolation.
# The `pi` wrapper fails loudly if srt is not installed.
#
# Unrestricted variant: `pi-unrestricted` bypasses the sandbox and does not
# require srt. No short form aliases are allowed — the full name makes the
# security implications explicit.
#
# Excluded: vscode, cursor (have built-in protections; no srt needed).
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
  # Activation scripts embed the repo root path at build time (threaded via
  # specialArgs, not getEnv) so lib files can be sourced at runtime without
  # builtins.readFile.  The baked path is the same one used for
  # mkOutOfStoreSymlink — if repoRoot is unset, both symlink targets and lib
  # sourcing will fail identically.
  effectiveUsername = config.home.username;
  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };
  clawhubManifestRelativePath = overlay.toRepoRelPath (
    overlay.selectFile "agents" "clawhub-skills.json"
  );

  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };

  # Read the consolidated lockfile so activation scripts can converge to
  # exact pins (closes the drift root cause).  Mirrors pwsh.nix.
  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);

  # Declarative desired package sets, keyed by manager and host.  Every
  # installer reads this file instead of carrying its own list, so a package
  # cannot be installed on one host and silently forgotten on another.  A
  # missing manager or host key is a hard error rather than an empty set -- an
  # empty set would make the zap-style convergence prune installed packages.
  packagesDesired = builtins.fromJSON (builtins.readFile ./packages/desired.json);
  desiredFor =
    manager:
    packagesDesired.${manager}.${hostName}
      or (throw "src/modules/packages/desired.json has no '${manager}' entry for host '${hostName}'");

  # Declarative superpowers fetch: evaluated at Nix build time, checked out
  # into the Nix store once.  Activation symlinks — no git, no network.
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
  # global commands under ~/.config/opencode/commands. Both are bridged to the
  # single shared agent-asset tree in ~/.agents/ (agents -> agents/, commands ->
  # prompts/) so nothing is duplicated. linkGeneration rewrites these two paths
  # on every apply, hence the unprotect/protect pairing around it.
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
  # symlinks in ~/.agents/. No Nix-level deployment needed — the scripts read
  # directly from the repo tree at activation time.
  home.activation = {
    # -------------------------------------------------------------------------
    # symlink-agent-config
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in the resolved agents overlay dir except
    # skills/ (which is managed by install-agent-skills so fetched ClawHub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    # -------------------------------------------------------------------------
    symlink-agent-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/agents/symlink-agent-config.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # -------------------------------------------------------------------------
    # install-agent-skills
    # Creates ~/.agents/skills/ as a real (writable) directory, then creates a
    # per-skill symlink inside it for every skill subdirectory committed to
    # the resolved agents overlay skills/ tree (bundled / AGPL-compatible skills).
    #
    # Fetched skills (non-AGPL / ClawHub-managed) are downloaded directly into
    # ~/.agents/skills/<name>/ by the post-apply sync step in apply.sh; they
    # are never committed to the repo and are not managed here.
    #
    # The skills/ tree is a real directory — not a symlink — so that:
    #   1. Bundled per-skill symlinks can coexist with fetched real dirs.
    #   2. ClawHub can write into ~/.agents/skills/ without the writes landing
    #      inside the tracked repo tree (which would happen with a whole-dir
    #      symlink back to the resolved agents overlay skills/ tree).
    #
    # Conflict safety: if a committed skill name collides with an existing real
    # directory in ~/.agents/skills/ (e.g. a fetched download), the activation
    # fails fast rather than silently overwriting the downloaded content.
    # -------------------------------------------------------------------------
    install-agent-skills = lib.hm.dag.entryAfter [ "symlink-agent-config" ] ''
      "${activationBundle}/src/scripts/agents/install-agent-skills.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # -------------------------------------------------------------------------
    # symlink-pi-agent-config
    # Symlinks Pi coding agent config files from ~/.agents/ into ~/.pi/agent/.
    #
    # Skills are handled natively by Pi (auto-discovered from ~/.agents/skills/
    # and .agents/skills/), so no symlink is needed for those.
    #
    # Why after install-agent-skills: the extensions/ and pi-settings.json
    # entries are deployed by symlink-agent-config.sh (which runs before
    # install-agent-skills), so they are available as symlink sources.
    # -------------------------------------------------------------------------
    symlink-pi-agent-config = lib.hm.dag.entryAfter [ "install-agent-skills" ] ''
      "${activationBundle}/src/scripts/agents/symlink-pi-agent-config.sh" "${repoRoot}" "${effectiveUsername}"
    '';

    # -------------------------------------------------------------------------
    # install-bun-packages
    # Idempotently converges the declarative bun global package set.
    #
    # Maintains a managed set of JS CLI tools installed via `bun install -g`.
    # On each apply it derives the installed set from bun's global package.json,
    # installs additions, and removes deletions.
    #
    # Only packages absent from nixpkgs and cargo-binstall are managed here
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    # The desired set and the per-package binary-name overrides live in
    # src/modules/packages/desired.json (bun, host-keyed).
    #
    # Why the node-gyp toolchain args: allowlisted packages run lifecycle
    # scripts, and bun rebuilds a native dependency through node-gyp when it
    # cannot use the shipped prebuild.  The activation PATH carries neither a
    # Python interpreter nor make, so gyp's find-python step would abort the
    # whole activation.
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # install-pi-packages
    # Idempotently converges the declarative pi coding agent npm package set.
    #
    # Reads the desired packages from src/modules/packages/desired.json and
    # the versions from the lockfile `pi` section, compares against actually
    # installed packages in ~/.pi/agent/npm/, installs missing or drifted
    # packages, and removes undesired ones.
    #
    # Why after install-bun-packages: logical grouping.  bun is passed
    # explicitly because pi spawns the bare command "bun" for every npm:
    # install (npmCommand in src/users/default/pi/settings.json), so
    # bun's directory must be on the child PATH, not only callable by path.
    # -------------------------------------------------------------------------
    install-pi-packages = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/packages/install-pi-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.pi-coding-agent}/bin/pi" \
        "${pkgs.gawk}/bin/awk" \
        '${builtins.toJSON (desiredFor "pi")}' \
        "${pkgs.bun}/bin"
    '';

    # -------------------------------------------------------------------------
    # install-uv-tools
    # Idempotently converges the declarative uv tool set (install + prune).
    #
    # Maintains a managed set of Python CLI tools installed via `uv tool install`.
    # On each apply it queries `uv tool list` for the actually installed set,
    # removes anything installed but absent from the desired list (zap-style),
    # and installs any desired tools that are missing.  The desired set lives in
    # src/modules/packages/desired.json (uv, host-keyed).
    #
    # Only tools absent from nixpkgs, cargo-binstall, and bun are managed here
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    # -------------------------------------------------------------------------
    install-uv-tools = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/packages/install-uv-tools.sh" \
        "${pkgs.uv}/bin/uv" \
        "${pkgs.gawk}/bin/awk" \
        "${pkgs.gnugrep}/bin/grep" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON (desiredFor "uv")}'
    '';

    # -------------------------------------------------------------------------
    # init-rustup
    # Initialises the rustup Rust toolchain manager on POSIX hosts, mirroring
    # the Windows Invoke-RustupSetup behaviour.
    #
    # Sets rustup default to none so rust-toolchain.toml is always authoritative
    # and installs the stable toolchain for cargo-binstall compilation fallback.
    #
    # Why after linkGeneration: must run before install-cargo-binstall-packages
    # (enforced by that step's entryAfter).
    # -------------------------------------------------------------------------
    init-rustup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/packages/init-rustup.sh" \
        "${pkgs.rustup}/bin/rustup" \
        "${pkgs.jq}/bin/jq"
    '';

    # -------------------------------------------------------------------------
    # install-cargo-binstall-packages
    # Converges the declarative cargo-binstall package set (install + zap).
    #
    # The desired set lives in src/modules/packages/desired.json
    # (cargo-binstall, host-keyed); versions come from the lockfile
    # `cargo-binstall` section.  Any crate installed via `cargo install` or
    # `cargo binstall` that is NOT in the desired list will be uninstalled
    # (zap).
    #
    # Cargo resolution: uses nixpkgs cargo directly (store-path arg) for
    # list/uninstall operations.  Runtime path probing (~/.cargo/bin) is
    # prohibited.
    #
    # Install priority: nixpkgs > cargo binstall > cargo > bun > uv.
    #
    # Why after init-rustup: the stable toolchain is needed for
    # cargo-binstall's compilation fallback strategy (--strategies compile);
    # init-rustup ensures stable is installed before this step.  Unified with
    # Windows Invoke-RustupSetup + Invoke-CargoBinstallSetup behavior.
    # -------------------------------------------------------------------------
    install-cargo-binstall-packages = lib.hm.dag.entryAfter [ "init-rustup" ] ''
      "${activationBundle}/src/scripts/packages/install-cargo-binstall-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.gawk}/bin/awk" \
        '${builtins.toJSON (desiredFor "cargo-binstall")}' \
        "${pkgs.cargo}/bin/cargo" \
        "${pkgs.cargo-binstall}/bin/cargo-binstall"
    '';

    # -------------------------------------------------------------------------
    # sync-clawhub-skills
    # Converges fetched skills (non-AGPL-compatible, downloaded at apply time
    # via ClawHub) with the declarative manifest in
    # declarative manifest in the resolved agents clawhub-skills.json overlay file.
    #
    # Why after install-bun-packages: requires the ClawHub CLI, which is
    # installed by install-bun-packages.  Ordering makes sure ClawHub is present
    # before this step tries to invoke it.
    #
    # Why best-effort: the system configuration applied successfully.  Skill
    # sync is additive; a missing skill does not break any declared system
    # state.
    # -------------------------------------------------------------------------
    sync-clawhub-skills = lib.hm.dag.entryAfter [ "install-bun-packages" ] ''
      "${activationBundle}/src/scripts/agents/sync-clawhub-skills.sh" \
        "${pkgs.jq}/bin/jq" \
        "${managedPaths.toShellPrependGuard}" \
        "${managedPaths.toShellAppendGuard}" \
        "${clawhubManifestRelativePath}" \
        "$HOME/${builtins.elemAt managedPaths.pathComponents.append 0}/clawhub"
    '';

    # -----------------------------------------------------------------------
    # symlink-superpowers-plugin
    # Declaratively provisions the superpowers plugin as a Nix store symlink.
    #
    # builtins.fetchGit evaluates at Nix build time, checking out the pinned
    # rev into /nix/store/.  Activation creates a stable symlink from
    # <nucleusUserRoot>/plugins/superpowers → the store path.
    #
    # Why after linkGeneration: ensures nucleus user root parent exists.
    # No dependency on bun/PATH guards — this is a pure store path.
    #
    # Why best-effort: the system configuration applied successfully.  A
    # missing plugin does not break any declared system state.
    # -----------------------------------------------------------------------
    symlink-superpowers-plugin = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/agents/symlink-superpowers-plugin.sh" \
        "${superpowersSrc}"
    '';

    # -----------------------------------------------------------------------
    # symlink-superpowers-skills
    # Symlinks superpowers skills into ~/.agents/skills/ via install-agent-skills.
    #
    # Extends install-agent-skills.sh with the superpowers skills directory.
    # Skills are auto-discovered by Pi, Cursor, and other agents.
    #
    # Why after install-agent-skills: install-agent-skills creates the base
    # ~/.agents/skills/ directory and symlinks bundled skills. We add
    # superpowers skills after that to avoid conflicts.
    #
    # Why after symlink-superpowers-plugin: needs the Nix store symlink
    # to exist so the skills directory is accessible.
    # -----------------------------------------------------------------------
    symlink-superpowers-skills =
      lib.hm.dag.entryAfter [ "install-agent-skills" "symlink-superpowers-plugin" ]
        ''
          "${activationBundle}/src/scripts/agents/install-agent-skills.sh" \
            "${repoRoot}" "${effectiveUsername}" \
            "${superpowersSrc}/skills"
        '';

    # -----------------------------------------------------------------------
    # symlink-superpowers-for-opencode
    # Wires OpenCode to use local superpowers plugin via method-1 symlink.
    #
    # Creates ~/.opencode/plugins/superpowers → Nix store superpowers plugin.
    #
    # Why after linkGeneration: ensures ~/.opencode/ parent exists.
    # Why best-effort: OpenCode is not installed on all hosts.
    # -----------------------------------------------------------------------
    symlink-superpowers-for-opencode =
      lib.hm.dag.entryAfter [ "linkGeneration" "symlink-superpowers-plugin" ]
        ''
          "${activationBundle}/src/scripts/agents/symlink-superpowers-for-opencode.sh"
        '';

  };
}
