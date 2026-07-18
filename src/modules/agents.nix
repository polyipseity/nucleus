# Declarative ~/.agents directory layout with per-entry symlinks into
# src/modules/configs/agents/ (skills/ managed by skills).
# Activation reads $NUCLEUS_REPO_ROOT for out-of-store symlinks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Activation scripts resolve the repo root dynamically from $NUCLEUS_REPO_ROOT
  # (set by apply.sh and forwarded through sudo), so out-of-store symlinks
  # survive repo relocations and rebuilds without stale store paths.
  # As a fallback, capture NUCLEUS_REPO_ROOT at eval time (where the env var IS
  # available) so home-manager activation, which runs as the user and does not
  # inherit the sudo-level env var, can still locate the repo root.
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Keep path fragments centralized so activation entries reference one source
  # of truth for the repo-hosted agents configuration tree.
  agentsConfigRelativePath = "src/modules/configs/agents";
  agentsSkillsRelativePath = "${agentsConfigRelativePath}/skills";
  clawhubManifestRelativePath = "${agentsConfigRelativePath}/clawhub-skills.json";

  # Inline shell helpers from the shared library file at build time so
  # activation scripts can use _nucleus_protect_symlink, _nucleus_unprotect_symlink,
  # _nucleus_resolve_repo_root, and _nucleus_prepend_first_executable_dir.
  symlinkHardeningLib = builtins.readFile ../scripts/lib/symlink-hardening-lib.sh;

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
    ${symlinkHardeningLib}
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation.protectOpencodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${symlinkHardeningLib}
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  # Method 4 (activation script manages whole-directory symlinks): the agents/
  # config directory is deployed via agents-symlink.sh which creates per-entry
  # symlinks in ~/.agents/. No Nix-level deployment needed — the scripts read
  # directly from the repo tree at activation time.
  home.activation = {
    # -------------------------------------------------------------------------
    # agents-symlink
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in src/modules/configs/agents/ except
    # skills/ (which is managed by agent-skills so fetched ClawHub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    # -------------------------------------------------------------------------
    agents-symlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      export REPO_ROOT="${repoRoot}"
      export AGENTS_CONFIG_RELATIVE_PATH="${agentsConfigRelativePath}"
      ${symlinkHardeningLib}
      ${builtins.readFile ../scripts/agents/agents-symlink.sh}
    '';

    # -------------------------------------------------------------------------
    # agent-skills
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
    agent-skills = lib.hm.dag.entryAfter [ "agents-symlink" ] ''
      set -eu

      export REPO_ROOT="${repoRoot}"
      export AGENTS_SKILLS_RELATIVE_PATH="${agentsSkillsRelativePath}"
      ${symlinkHardeningLib}
      ${builtins.readFile ../scripts/agents/agent-skills.sh}
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
    # (install preference: nixpkgs > cargo binstall > bun > uv).
    #
    # Currently managed:
    #   clawhub — fetched skill install vehicle; absent from nixpkgs and
    #             cargo-binstall; bun is the only viable install tier.
    # -------------------------------------------------------------------------
    installBunPackages = lib.hm.dag.entryAfter [ "agent-skills" ] ''
      set -eu

      export JQ_BIN='${pkgs.jq}/bin/jq'
      ${symlinkHardeningLib}

      # Add managed bin directories (managed-paths.nix pathComponents) to PATH
      # so binaries installed by previous apply runs and by this activation are
      # discoverable in subsequent activation steps without spawning a new
      # shell session.
      PATH="${managedPaths.toShellPrependGuard}$PATH${managedPaths.toShellAppendGuard}"
      export PATH

      # Also prepend the nix profile bin directory, Home Manager profile bin
      # directory, and directly probe the nix store for common package bins.
      # After linkGeneration the profile symlinks exist, but the activation
      # shell's PATH may not include them.
      _nucleus_prepend_first_executable_dir bun \
        ${managedPaths.nixProfileBinDirs} || true  # undoc-supp: bun may not be in any profile dir; fallback follows.

      ${builtins.readFile ../scripts/configs/install-bun-packages.sh}
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
    # (install preference: nixpkgs > cargo binstall > bun > uv).
    # -------------------------------------------------------------------------
    installUvTools = lib.hm.dag.entryAfter [ "installBunPackages" ] (
      # Preamble: set -eu and source symlink hardening lib.
      # The external script depends on functions from the hardening lib
      # being available at activation time.
      ''
        set -eu
        ${symlinkHardeningLib}
      ''
      +
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
          (builtins.readFile ../scripts/agents/install-uv-tools.sh)
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
      ''
        set -eu
        ${symlinkHardeningLib}
      ''
      +
        builtins.replaceStrings
          [ "__MANAGED_NIX_SYSTEM_BIN_DIRS__" "__MANAGED_NIX_PROFILE_BIN_DIRS__" ]
          [ "${managedPaths.nixSystemBinDirs}" "${managedPaths.nixProfileBinDirs}" ]
          (builtins.readFile ../scripts/agents/init-rustup.sh)
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
      ''
        set -eu
        ${symlinkHardeningLib}
      ''
      +
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
          (builtins.readFile ../scripts/agents/install-cargo-binstall-packages.sh)
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
    syncClawHubSkills = lib.hm.dag.entryAfter [ "installBunPackages" ] ''
      set -eu

      _scs_jq_bin='${pkgs.jq}/bin/jq'
      ${symlinkHardeningLib}

      _scs_do_sync=true

      # Add managed bin directories (managed-paths.nix pathComponents) to PATH
      # so the ClawHub binary installed by installBunPackages is on PATH for
      # this activation step.
      PATH="${managedPaths.toShellPrependGuard}$PATH${managedPaths.toShellAppendGuard}"
      export PATH

      # Resolve the repo root (same mechanism as symlink and skills).
      _scs_repo_root="$(_nucleus_resolve_repo_root "clawhub" "${repoRoot}")"

      # Path to the declarative fetched skill manifest.  Slugs listed here are
      # downloaded by ClawHub; slugs absent from the manifest are cleaned up
      # from ~/.agents/skills/ when their .clawhub/origin.json marker is
      # present.
      _scs_manifest="$_scs_repo_root/${clawhubManifestRelativePath}"
      if [ ! -f "$_scs_manifest" ]; then
        echo "clawhub: manifest not found at $_scs_manifest; skipping fetched skill sync"
        _scs_do_sync=false
      fi

      _scs_slugs_file="$(mktemp)"
      if [ "$_scs_do_sync" = true ]; then
        "$_scs_jq_bin" -r '.skills[]?' "$_scs_manifest" > "$_scs_slugs_file"

        if [ ! -s "$_scs_slugs_file" ]; then
          echo "clawhub: no fetched skills in manifest; skipping"
          _scs_do_sync=false
        fi
      fi

      _scs_skills_dir="$HOME/.agents/skills"

      # Ensure ~/.agents/skills/ exists.  The skills activation creates
      # it during home-manager switch; this guards against running before that
      # activation has run.
      if [ ! -d "$_scs_skills_dir" ]; then
        mkdir -p "$_scs_skills_dir"
      fi

      # Probe for the ClawHub CLI.  ClawHub must be pre-installed by the
      # installBunPackages activation before this step is called; this step
      # never installs ClawHub itself.
      if [ "$_scs_do_sync" = true ] && ! command -v clawhub >/dev/null 2>&1; then
        echo "clawhub: clawhub not found in PATH; installBunPackages must complete before fetched skill sync; skipping" >&2
        _scs_do_sync=false
      fi

      if [ "$_scs_do_sync" = true ]; then
        echo "clawhub: running fetched skill sync..."

        # Install or update each skill from the manifest.
        #   --workdir "$HOME/.agents" installs to $HOME/.agents/skills/<slug>/
        #                            (default --dir value is "skills")
        #   --no-input               disables interactive prompts for apply safety
        while IFS= read -r _scs_slug; do
          [ -z "$_scs_slug" ] && continue
          _scs_skill_path="$_scs_skills_dir/$_scs_slug"
          if [ -L "$_scs_skill_path" ]; then
            # A committed-skill (bundled) symlink exists with the same slug.
            # Skip to avoid overwriting the managed symlink; the slug must be
            # removed from clawhub-skills.json or the committed skill removed.
            echo "clawhub: skipping '$_scs_slug' — a committed-skill symlink exists at $_scs_skill_path" >&2
            continue
          fi
          # Unlock an existing fetched skill directory before updating so
          # ClawHub can overwrite files locked a-w on a previous install.
          if [ -d "$_scs_skill_path" ]; then
            chmod -R u+w "$_scs_skill_path"
          fi
          echo "clawhub: installing/updating fetched skill '$_scs_slug'..."
          # Best-effort: non-zero exit from ClawHub is non-fatal because the
          # system apply already succeeded and skill sync is additive.
          if clawhub install --workdir "$HOME/.agents" --no-input "$_scs_slug"; then
            # Lock installed content so files cannot be modified outside a
            # managed apply run.  The unlock above re-opens write access before
            # the next update.
            if [ -d "$_scs_skill_path" ]; then
              chmod -R a-w "$_scs_skill_path"
            fi
          else
            echo "clawhub: clawhub install failed for '$_scs_slug' (system apply succeeded)" >&2
          fi
        done < "$_scs_slugs_file"

        # Stale cleanup: remove real directories in ~/.agents/skills/ that have
        # a .clawhub/origin.json marker (written by ClawHub at install time,
        # identifying fetched downloads) but whose slug is no longer in manifest.
        # Directories without this marker (bundled symlinks or user content) are
        # never touched.
        _scs_stale_list="$(mktemp)"
        find "$_scs_skills_dir" -mindepth 1 -maxdepth 1 -type d > "$_scs_stale_list"
        while IFS= read -r _scs_candidate; do
          [ -z "$_scs_candidate" ] && continue
          _scs_name="$(basename "$_scs_candidate")"
          [ ! -f "$_scs_candidate/.clawhub/origin.json" ] && continue
          if ! grep -qxF "$_scs_name" "$_scs_slugs_file"; then
            echo "clawhub: removing stale fetched skill '$_scs_name' (removed from manifest)"
            # Unlock before removal: fetched skill trees are locked a-w after
            # install, so rm -rf needs write access restored first.
            chmod -R u+w "$_scs_candidate"
            rm -rf "$_scs_candidate"
          fi
        done < "$_scs_stale_list"
        rm -f "$_scs_stale_list"
        echo "clawhub: fetched skill sync complete"
      fi

      rm -f "$_scs_slugs_file"
    '';
  };
}
