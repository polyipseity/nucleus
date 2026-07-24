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
  clawhubManifestRelativePath = "${agentsConfigRelativePath}/clawhub-skills.json";

  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  home.file = {
    ".config/opencode/agents".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/agents";
    ".config/opencode/commands".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/prompts";
  };

  home.activation.unprotectOpencodeSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "unprotect" "agents.nix" "$HOME/.config/opencode/agents"
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "unprotect" "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation.protectOpencodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "agents.nix" "$HOME/.config/opencode/agents"
    "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "agents.nix" "$HOME/.config/opencode/commands"
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
    symlink-agent-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/agents/symlink-agent-config.sh" "${repoRoot}" "${agentsConfigRelativePath}"
    '';

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
    install-agent-skills = lib.hm.dag.entryAfter [ "symlink-agent-config" ] ''
      "${activationBundle}/src/scripts/agents/install-agent-skills.sh" "${repoRoot}"
    '';

    # -------------------------------------------------------------------------
    # installBunPackages
    # Idempotently converges the declarative bun global package set.
    #
    # Maintains a managed set of JS CLI tools installed via `bun install -g`.
    # On each apply it derives the installed set from bun's global package.json,
    # installs additions, and removes deletions.
    #
    # Only packages absent from nixpkgs and cargo-binstall are managed here
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    #
    # Currently managed:
    #   clawhub — fetched skill install vehicle; absent from nixpkgs and
    #             cargo-binstall; bun is the only viable install tier.
    # -------------------------------------------------------------------------
    installBunPackages = lib.hm.dag.entryAfter [ "install-agent-skills" ] ''
      "${activationBundle}/src/scripts/packages/install-bun-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.bun}/bin/bun"
    '';

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
    # (install preference: nixpkgs > cargo binstall > cargo > bun > uv).
    # -------------------------------------------------------------------------
    installUvTools = lib.hm.dag.entryAfter [ "installBunPackages" ] ''
      "${activationBundle}/src/scripts/packages/install-uv-tools.sh" \
        "${pkgs.uv}/bin/uv" \
        "${pkgs.gawk}/bin/awk" \
        "${pkgs.gnugrep}/bin/grep" \
        "${pkgs.jq}/bin/jq" \
        '${
          builtins.toJSON {
            # PaddleOCR: cross-platform OCR with GPU auto-detection.  uv for
            # cross-host version consistency (nixpkgs v3.5.0, PyPI v3.6.0).
            # Pinned to Python 3.11 because its dependency opencv-contrib-python
            # cannot build on Python >=3.12 (distutils removed).
            paddleocr = "3.11";
          }
        }'
    '';

    # -------------------------------------------------------------------------
    # initRustup
    # Initialises the rustup Rust toolchain manager on POSIX hosts, mirroring
    # the Windows Invoke-RustupSetup behaviour.
    #
    # Sets rustup default to none so rust-toolchain.toml is always authoritative
    # and installs the stable toolchain for cargo-binstall compilation fallback.
    #
    # Why after linkGeneration: must run before installCargoBinstallPackages
    # (enforced by that step's entryAfter).
    # -------------------------------------------------------------------------
    initRustup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/scripts/packages/init-rustup.sh" \
        "${pkgs.rustup}/bin/rustup"
    '';

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
    # Cargo resolution: uses nixpkgs cargo directly (store-path arg) for
    # list/uninstall operations.  Runtime path probing (~/.cargo/bin) is
    # prohibited.
    #
    # Install priority: nixpkgs > cargo binstall > cargo > bun > uv.
    #
    # Why after initRustup: the stable toolchain is needed for
    # cargo-binstall's compilation fallback strategy (--strategies compile);
    # initRustup ensures stable is installed before this step.  Unified with
    # Windows Invoke-RustupSetup + Invoke-CargoBinstallSetup behavior.
    # -------------------------------------------------------------------------
    installCargoBinstallPackages = lib.hm.dag.entryAfter [ "initRustup" ] ''
      "${activationBundle}/src/scripts/packages/install-cargo-binstall-packages.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.gawk}/bin/awk" \
        '${builtins.toJSON [ ]}' \
        "${pkgs.cargo}/bin/cargo"
    '';

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
    syncClawHubSkills = lib.hm.dag.entryAfter [ "installBunPackages" ] ''
      "${activationBundle}/src/scripts/agents/sync-clawhub-skills.sh" \
        "${pkgs.jq}/bin/jq" \
        "${managedPaths.toShellPrependGuard}" \
        "${managedPaths.toShellAppendGuard}" \
        "${repoRoot}" \
        "${clawhubManifestRelativePath}"
    '';
  };
}
