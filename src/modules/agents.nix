# Declarative ~/.agents directory layout with per-entry symlinks into
# src/modules/configs/agents/ (skills/ managed by skills).
# The repo root is baked at build time from $NUCLEUS_REPO_ROOT for out-of-store
# symlink sources and lib runtime-sourcing paths.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Activation scripts embed the repo root path at build time (from
  # $NUCLEUS_REPO_ROOT, set by apply.sh) so lib files can be sourced
  # at runtime without builtins.readFile.  The baked path is the same
  # one used for mkOutOfStoreSymlink — if NUCLEUS_REPO_ROOT is unset,
  # both symlink targets and lib sourcing will fail identically.
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Keep path fragments centralized so activation entries reference one source
  # of truth for the repo-hosted agents configuration tree.
  agentsConfigRelativePath = "src/modules/configs/agents";
  agentsSkillsRelativePath = "${agentsConfigRelativePath}/skills";
  clawhubManifestRelativePath = "${agentsConfigRelativePath}/clawhub-skills.json";

  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };

in
{
  home.file = {
    ".config/opencode/agents".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/agents";
    ".config/opencode/commands".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/prompts";
  };

  home.activation.unprotectOpencodeSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation.protectOpencodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/lib/symlink-hardening-lib.sh}
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  # Method 4 (activation script manages whole-directory symlinks): the agents/
  # config directory is deployed via symlink-agent-config.sh which creates per-entry
  # symlinks in ~/.agents/. No Nix-level deployment needed — the scripts read
  # directly from the repo tree at activation time.
  home.activation = {
    # -------------------------------------------------------------------------
    # symlink-agent-config
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in src/modules/configs/agents/ except
    # skills/ (which is managed by install-agent-skills so fetched ClawHub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    # -------------------------------------------------------------------------
    symlink-agent-config = lib.hm.dag.entryAfter [ "linkGeneration" ] (
      builtins.readFile ../scripts/agents/symlink-agent-config.sh
    );

    # -------------------------------------------------------------------------
    # install-agent-skills
    # Creates ~/.agents/skills/ as a real (writable) directory, then creates a
    # per-skill symlink inside it for every skill subdirectory committed to
    # src/modules/configs/agents/skills/ (bundled / AGPL-compatible skills).
    #
    # Fetched skills (non-AGPL / ClawHub-managed) are downloaded directly into
    # ~/.agents/skills/<name>/ by the post-apply sync step in apply.sh; they
    # are never committed to the repo and are not managed here.
    #
    # The skills/ tree is a real directory — not a symlink — so that:
    #   1. Bundled per-skill symlinks can coexist with fetched real dirs.
    #   2. ClawHub can write into ~/.agents/skills/ without the writes landing
    #      inside the tracked repo tree (which would happen with a whole-dir
    #      symlink back to src/modules/configs/agents/skills/).
    #
    # Conflict safety: if a committed skill name collides with an existing real
    # directory in ~/.agents/skills/ (e.g. a fetched download), the activation
    # fails fast rather than silently overwriting the downloaded content.
    # -------------------------------------------------------------------------
    install-agent-skills = lib.hm.dag.entryAfter [ "symlink-agent-config" ] (
      builtins.readFile ../scripts/agents/install-agent-skills.sh
    );

    # -------------------------------------------------------------------------
    # installBunPackages
    # Idempotently converges the declarative bun global package set.
    #
    # Maintains a managed set of JS CLI tools installed via `bun install -g`.
    # On each apply it derives the installed set from bun's global package.json,
    # installs additions, and removes deletions.
    #
    # Only packages absent from nixpkgs and cargo-binstall are managed here
    # (install preference: nixpkgs > cargo binstall > bun > uv).
    #
    # Currently managed:
    #   clawhub — fetched skill install vehicle; absent from nixpkgs and
    #             cargo-binstall; bun is the only viable install tier.
    # -------------------------------------------------------------------------
    installBunPackages = lib.hm.dag.entryAfter [ "install-agent-skills" ] (
      builtins.replaceStrings
        [ "__JQ_BIN__" "__MANAGED_PREPEND_GUARD__" "__MANAGED_APPEND_GUARD__" "__NIX_PROFILE_BIN_DIRS__" ]
        [
          "${pkgs.jq}/bin/jq"
          managedPaths.toShellPrependGuard
          managedPaths.toShellAppendGuard
          managedPaths.nixProfileBinDirs
        ]
        (builtins.readFile ../scripts/packages/install-bun-packages.sh)
    );

    # -------------------------------------------------------------------------
    # installUvTools
    # Idempotently converges the declarative uv tool set (install + prune).
    #
    # Maintains a managed set of Python CLI tools installed via `uv tool install`.
    # On each apply it queries `uv tool list` for the actually installed set,
    # removes anything installed but absent from the desired list (zap-style),
    # and installs any desired tools that are missing.
    #
    # Only tools absent from nixpkgs, cargo-binstall, and bun are managed here
    # (install preference: nixpkgs > cargo binstall > bun > uv).
    # -------------------------------------------------------------------------
    installUvTools = lib.hm.dag.entryAfter [ "installBunPackages" ] (
      builtins.replaceStrings
        [ "__UV_BIN__" "__GAWK_BIN__" "__GREP_BIN__" "__JQ_BIN__" "__DESIRED_UV_TOOLS_JSON__" ]
        [
          "${pkgs.uv}/bin/uv"
          "${pkgs.gawk}/bin/awk"
          "${pkgs.gnugrep}/bin/grep"
          "${pkgs.jq}/bin/jq"
          # Desired tools as JSON object mapping tool name → Python version
          # (empty string = use default).  Only add tools absent from nixpkgs,
          # cargo-binstall, and bun (install preference: nixpkgs > cargo binstall > bun > uv).
          (builtins.toJSON {
            # PaddleOCR: cross-platform OCR with GPU auto-detection.  uv for
            # cross-host version consistency (nixpkgs v3.5.0, PyPI v3.6.0).
            # Pinned to Python 3.11 because its dependency opencv-contrib-python
            # cannot build on Python >=3.12 (distutils removed).
            paddleocr = "3.11";
          })
        ]
        (builtins.readFile ../scripts/packages/install-uv-tools.sh)
    );

    # -------------------------------------------------------------------------
    # initRustup
    # Initialises the rustup Rust toolchain manager on POSIX hosts, mirroring
    # the Windows Invoke-RustupSetup behaviour.
    #
    # Sets rustup default to none so rust-toolchain.toml is always authoritative
    # and installs the stable toolchain for cargo-binstall compilation fallback
    # and for cargo +stable list/uninstall operations in the next step.
    #
    # Why after linkGeneration: pkgs.rustup (linked by linkGeneration) must be
    # on PATH before this step invokes it to configure the toolchain state.
    # -------------------------------------------------------------------------
    initRustup = lib.hm.dag.entryAfter [ "linkGeneration" ] (
      builtins.replaceStrings
        [ "__MANAGED_NIX_SYSTEM_BIN_DIRS__" "__MANAGED_NIX_PROFILE_BIN_DIRS__" ]
        [ "${managedPaths.nixSystemBinDirs}" "${managedPaths.nixProfileBinDirs}" ]
        (builtins.readFile ../scripts/packages/init-rustup.sh)
    );

    # -------------------------------------------------------------------------
    # installCargoBinstallPackages
    # Converges the declarative cargo-binstall package set (install + zap).
    #
    # On POSIX hosts all packages that would otherwise require cargo-binstall
    # are available in nixpkgs (e.g. pay-respects, cargo-cache), so the
    # desired list is intentionally empty.  Any crate installed via
    # `cargo install` or `cargo binstall` that is NOT in the desired list will
    # be uninstalled (zap).
    #
    # Mirrors homebrew cleanup = "zap": removes anything installed but absent
    # from the declared desired set, regardless of how it was installed.
    #
    # Why after initRustup: cargo is provided by rustup's stable toolchain via
    # ~/.cargo/bin; initRustup ensures stable is installed before this step
    # invokes `cargo +stable` for list and uninstall operations.  Unified with
    # Windows Invoke-RustupSetup + Invoke-CargoBinstallSetup behavior.
    # -------------------------------------------------------------------------
    installCargoBinstallPackages = lib.hm.dag.entryAfter [ "initRustup" ] (
      builtins.replaceStrings
        [
          "__JQ_BIN__"
          "__GAWK_BIN__"
          "__DESIRED_CRATES_JSON__"
          "__CARGO_BIN_DIR__"
          "__NIX_SYSTEM_BIN_DIRS__"
          "__NIX_PROFILE_BIN_DIRS__"
        ]
        [
          "${pkgs.jq}/bin/jq"
          "${pkgs.gawk}/bin/awk"
          # On POSIX hosts this list is intentionally empty because all
          # managed Rust tools are provided by nixpkgs (install preference:
          # nixpkgs > cargo binstall > bun > uv).
          (builtins.toJSON [ ])
          "${managedPaths.cargoBinDir}"
          "${managedPaths.nixSystemBinDirs}"
          "${managedPaths.nixProfileBinDirs}"
        ]
        (builtins.readFile ../scripts/packages/install-cargo-binstall-packages.sh)
    );

    # -------------------------------------------------------------------------
    # syncClawHubSkills
    # Converges fetched skills (non-AGPL-compatible, downloaded at apply time
    # via ClawHub) with the declarative manifest in
    # src/modules/configs/agents/clawhub-skills.json.
    #
    # Why after installBunPackages: requires the ClawHub CLI, which is
    # installed by installBunPackages.  Ordering ensures ClawHub is present
    # before this step tries to invoke it.
    #
    # Why best-effort: the system configuration applied successfully.  Skill
    # sync is additive; a missing skill does not break any declared system
    # state.
    # -------------------------------------------------------------------------
    syncClawHubSkills = lib.hm.dag.entryAfter [ "installBunPackages" ] (
      builtins.replaceStrings
        [
          "__JQ_BIN__"
          "__PATH_PREPEND_GUARD__"
          "__PATH_APPEND_GUARD__"
          "__REPO_ROOT__"
          "__CLAWHUB_MANIFEST_RELATIVE_PATH__"
        ]
        [
          "${pkgs.jq}/bin/jq"
          "${managedPaths.toShellPrependGuard}"
          "${managedPaths.toShellAppendGuard}"
          "${repoRoot}"
          "${clawhubManifestRelativePath}"
        ]
        (builtins.readFile ../scripts/agents/sync-clawhub-skills.sh)
    );
  };
}
