# Declarative ~/.agents directory layout with per-entry symlinks into
# src/modules/configs/agents/ (skills/ managed by agentsSkills).
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
  agentHelpersSh = builtins.readFile ../scripts/agent-helpers.sh;
in
{
  home.file = {
    ".config/opencode/agents".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/agents";
    ".config/opencode/commands".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/prompts";
  };

  home.activation.unprotectOpencodeSymlinks = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    ${agentHelpersSh}
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation.protectOpencodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${agentHelpersSh}
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/agents"
    _nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/commands"
  '';

  home.activation = {
    # -------------------------------------------------------------------------
    # agentsSymlink
    # Creates ~/.agents/ as a real directory and populates it with per-entry
    # symlinks for every top-level entry in src/modules/configs/agents/ except
    # skills/ (which is managed by agentsSkills so fetched ClawHub downloads
    # land in a real, untracked directory rather than inside the repo tree).
    # -------------------------------------------------------------------------
    agentsSymlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      ${agentHelpersSh}

      # Resolve the repo root so the activation can construct an absolute path
      # to src/modules/configs/agents/ regardless of where the repo is checked
      # out.  $NUCLEUS_REPO_ROOT is set by apply.sh and forwarded through sudo.
      _as_repo_root="$(_nucleus_resolve_repo_root "agents-config" "${repoRoot}")"

      _as_agents_source="$_as_repo_root/${agentsConfigRelativePath}"
      if [ ! -d "$_as_agents_source" ]; then
        echo "agents-config: agents config dir not found: $_as_agents_source" >&2
        exit 1
      fi

      _as_agents_dir="$HOME/.agents"

      # Ensure ~/.agents exists as a real (writable) directory.
      if [ ! -d "$_as_agents_dir" ]; then
        mkdir "$_as_agents_dir"
        echo "agents-config: created $HOME/.agents"
      elif [ -e "$_as_agents_dir" ] && [ ! -d "$_as_agents_dir" ]; then
        # Unexpected non-directory file: fail fast.
        echo "agents-config: $HOME/.agents exists but is not a directory — remove it and re-run apply." >&2
        exit 1
      fi

      # Remove stale per-subdir symlinks: any symlink in ~/.agents/ that once
      # pointed into _as_agents_source/ but whose source entry no longer exists.
      # This keeps ~/.agents/ free of dangling links after source entries are
      # removed from the repo.  skills/ is skipped — agentsSkills owns it.
      find "$_as_agents_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _as_candidate; do
        _as_cname="$(basename "$_as_candidate")"
        [ "$_as_cname" = "skills" ] && continue
        _as_ctarget="$(readlink "$_as_candidate")"
        case "$_as_ctarget" in
          "$_as_agents_source"/*)
            # Managed per-subdir symlink: remove if its source no longer exists.
            if [ ! -e "$_as_ctarget" ] && [ ! -L "$_as_ctarget" ]; then
              _nucleus_unprotect_symlink "agents-config" "$_as_candidate"
              rm "$_as_candidate"
              echo "agents-config: removed stale link for $_as_cname (source removed)"
            fi
            ;;
        esac
      done

      # Create or update per-entry symlinks for every top-level source entry
      # except skills/ (managed independently by agentsSkills).
      find "$_as_agents_source" -mindepth 1 -maxdepth 1 | while IFS= read -r _as_entry; do
        _as_name="$(basename "$_as_entry")"
        # skills/ is managed by agentsSkills; skip it here to avoid conflicts
        # with the real directory that agentsSkills creates for fetched downloads.
        [ "$_as_name" = "skills" ] && continue
        _as_link="$_as_agents_dir/$_as_name"
        if [ -L "$_as_link" ]; then
          if [ "$(readlink "$_as_link")" = "$_as_entry" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target (e.g. leftover from a previous checkout path): replace.
          _nucleus_unprotect_symlink "agents-config" "$_as_link"
          rm "$_as_link"
          ln -s "$_as_entry" "$_as_link"
          _nucleus_protect_symlink "agents-config" "$_as_link"
          echo "agents-config: updated $HOME/.agents/$_as_name -> $_as_entry"
        elif [ -e "$_as_link" ]; then
          # Real file or directory: fail fast to prevent silent data loss.
          echo "agents-config: $HOME/.agents/$_as_name is not a managed symlink — merge any wanted content into $_as_entry and remove it, then re-run apply." >&2
          exit 1
        else
          ln -s "$_as_entry" "$_as_link"
          _nucleus_protect_symlink "agents-config" "$_as_link"
          echo "agents-config: linked $HOME/.agents/$_as_name -> $_as_entry"
        fi
      done

      # Create the ~/.config/opencode/opencode.jsonc symlink to the repo-hosted
      # user config. Resolved at activation time (rather than via Nix-level
      # mkOutOfStoreSymlink) so the link still works after the repo root path
      # changes between rebuilds.
      mkdir -p "$HOME/.config/opencode"
      _as_opencode_source="$_as_repo_root/${agentsConfigRelativePath}/opencode.user.jsonc"
      _as_opencode_link="$HOME/.config/opencode/opencode.jsonc"
      if [ -L "$_as_opencode_link" ]; then
        if [ "$(readlink "$_as_opencode_link")" != "$_as_opencode_source" ]; then
          rm "$_as_opencode_link"
        fi
      elif [ -e "$_as_opencode_link" ]; then
        echo "agents-config: $_as_opencode_link exists and is not a managed symlink — remove or back it up, then re-run apply." >&2
        exit 1
      fi
      if [ ! -e "$_as_opencode_link" ]; then
        ln -s "$_as_opencode_source" "$_as_opencode_link"
        echo "agents-config: linked $HOME/.config/opencode/opencode.jsonc"
      fi
    '';

    # -------------------------------------------------------------------------
    # agentsSkills
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
    agentsSkills = lib.hm.dag.entryAfter [ "agentsSymlink" ] ''
      set -eu

      ${agentHelpersSh}

      # Resolve the repo root (same mechanism as agentsSymlink above).
      _ask_repo_root="$(_nucleus_resolve_repo_root "agents-skills" "${repoRoot}")"

      _ask_skills_source="$_ask_repo_root/${agentsSkillsRelativePath}"
      if [ ! -d "$_ask_skills_source" ]; then
        echo "agents-skills: skills source dir not found: $_ask_skills_source" >&2
        exit 1
      fi

      _ask_skills_dir="$HOME/.agents/skills"

      # Ensure ~/.agents/skills/ exists as a real directory so fetched ClawHub
      # downloads can be written here without entering the tracked repo tree.
      if [ ! -d "$_ask_skills_dir" ]; then
        mkdir -p "$_ask_skills_dir"
        echo "agents-skills: created $HOME/.agents/skills"
      fi

      # Remove stale per-skill symlinks: skill dirs that once existed in the
      # source but have since been removed from the repo.
      find "$_ask_skills_dir" -mindepth 1 -maxdepth 1 -type l | while IFS= read -r _ask_candidate; do
        _ask_cname="$(basename "$_ask_candidate")"
        _ask_ctarget="$(readlink "$_ask_candidate")"
        case "$_ask_ctarget" in
          "$_ask_skills_source"/*)
            # Managed per-skill symlink: remove if its source no longer exists.
            if [ ! -e "$_ask_ctarget" ] && [ ! -L "$_ask_ctarget" ]; then
              _nucleus_unprotect_symlink "agents-skills" "$_ask_candidate"
              rm "$_ask_candidate"
              echo "agents-skills: removed stale skill link for $_ask_cname (source removed)"
            fi
            ;;
        esac
      done

      # Create or update per-skill symlinks for every subdirectory committed to
      # src/modules/configs/agents/skills/.  Non-directory entries (.gitkeep etc.)
      # are skipped; only skill directories are linked.
      find "$_ask_skills_source" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r _ask_skill_dir; do
        _ask_skill_name="$(basename "$_ask_skill_dir")"
        _ask_link="$_ask_skills_dir/$_ask_skill_name"
        if [ -L "$_ask_link" ]; then
          if [ "$(readlink "$_ask_link")" = "$_ask_skill_dir" ]; then
            continue  # Correct symlink — no-op.
          fi
          # Wrong target: replace symlink.
          _nucleus_unprotect_symlink "agents-skills" "$_ask_link"
          rm "$_ask_link"
          ln -s "$_ask_skill_dir" "$_ask_link"
          _nucleus_protect_symlink "agents-skills" "$_ask_link"
          echo "agents-skills: updated $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        elif [ -d "$_ask_link" ]; then
          # Real directory in place of a committed skill — could be a fetched
          # download with the same name, or user data.  Fail fast to prevent
          # silent overwrites; the operator must resolve the conflict manually.
          echo "agents-skills: $HOME/.agents/skills/$_ask_skill_name is a real directory — if it is a fetched ClawHub download for a skill that has been re-committed, remove it and re-run apply." >&2
          exit 1
        else
          ln -s "$_ask_skill_dir" "$_ask_link"
          _nucleus_protect_symlink "agents-skills" "$_ask_link"
          echo "agents-skills: linked $HOME/.agents/skills/$_ask_skill_name -> $_ask_skill_dir"
        fi
      done
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
    installBunPackages = lib.hm.dag.entryAfter [ "agentsSkills" ] ''
      set -eu

      _ibp_jq_bin='${pkgs.jq}/bin/jq'
      ${agentHelpersSh}

      # Prepend ~/.bun/bin so binaries installed by previous apply runs and
      # by this activation are discoverable in subsequent activation steps
      # without spawning a new shell session.  bun install -g places binaries
      # here by default (BUN_INSTALL_BIN defaults to ~/.bun).
      if [ -d "$HOME/.bun/bin" ]; then
        PATH="$HOME/.bun/bin:$PATH"
        export PATH
      fi

      # Also prepend the nix profile bin directory, Home Manager profile bin
      # directory, and directly probe the nix store for common package bins.
      # After linkGeneration the profile symlinks exist, but the activation
      # shell's PATH may not include them.
      _nucleus_prepend_first_executable_dir bun \
        "$HOME/.local/state/nix/profiles/profile/bin" \
        "$HOME/.nix-profile/bin" \
        "$HOME/.local/state/home-manager/profile/bin" \
        "$HOME/.local/home-manager/profile/bin" || true  # undoc-supp: bun may not be in any profile dir; fallback follows.

      # If bun is still not found, search the nix store for any bun binary
      # and add its parent directory to PATH.
      if ! command -v bun >/dev/null 2>&1; then
        # undoc-supp: nix store may not have bun yet on first apply; best-effort store probe.
        _bun_store_path="$(find /nix/store -name 'bun' -type f -print -quit 2>/dev/null || true)"
        if [ -n "$_bun_store_path" ] && [ -x "$_bun_store_path" ]; then
          _bun_store_dir="$(dirname "$_bun_store_path")"
          PATH="$_bun_store_dir:$PATH"
          export PATH
        fi
      fi

      # bun is provided by pkgs.bun in core.nix (baseSharedPackages).  Verify
      # bun is now on PATH after the profile directory probes above.  Fail fast
      # if bun remains absent so the operator knows a full apply is needed.
      if ! command -v bun >/dev/null 2>&1; then
        echo "bun: bun not found in PATH; cannot install bun global packages" >&2
        exit 1
      fi

      # Declarative desired-state list.  One package per line.
      # Add a package name here to install it; remove it to trigger uninstall
      # on the next apply.  Only add packages absent from nixpkgs and
      # cargo-binstall (install preference: nixpkgs > cargo binstall > bun > uv).
      _ibp_desired="$(mktemp)"
      printf '%s\n' \
        'clawhub' \
        > "$_ibp_desired"

      # Get actually installed global packages from bun's authoritative package
      # registry (zap-style: remove any installed package absent from the desired
      # list, regardless of prior managed state).  The global package.json is
      # bun's canonical record of all globally-installed packages.
      _ibp_global_json="$HOME/.bun/install/global/package.json"
      _ibp_installed="$(mktemp)"
      if [ -f "$_ibp_global_json" ]; then
        # undoc-supp: parse failure on a malformed or partially-written file treats the installed set as empty — safe because desired packages will simply be re-installed on the next run.
        "$_ibp_jq_bin" -r '.dependencies // {} | keys[]' "$_ibp_global_json" > "$_ibp_installed" || true
      fi

      # Packages installed but not desired: zap-style removal.
      # Mirrors homebrew cleanup = "zap": removes anything installed but absent
      # from the declared desired set, regardless of how it was installed.
      _ibp_to_remove="$(mktemp)"
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        if ! grep -qxF "$_ibp_pkg" "$_ibp_desired"; then
          printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_remove"
        fi
      done < "$_ibp_installed"

      # Desired packages not yet in bun's global package.json, or whose binary
      # is absent from ~/.bun/bin (re-install needed).  Binary name = last path
      # component after '/' so @scope/name becomes name (bun uses the unscoped
      # basename as the binary name).
      _ibp_to_install="$(mktemp)"
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        _ibp_bin="''${_ibp_pkg##*/}"
        if ! grep -qxF "$_ibp_pkg" "$_ibp_installed" || \
           { [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
             [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; }; then
          printf '%s\n' "$_ibp_pkg" >> "$_ibp_to_install"
        fi
      done < "$_ibp_desired"

      # Remove packages no longer in the desired list.
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        echo "bun: removing $_ibp_pkg"
        if ! bun remove -g "$_ibp_pkg"; then
          echo "bun: 'bun remove -g $_ibp_pkg' failed" >&2
          rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
      done < "$_ibp_to_remove"

      # Install packages whose binary is absent from ~/.bun/bin.
      while IFS= read -r _ibp_pkg; do
        [ -z "$_ibp_pkg" ] && continue
        echo "bun: installing $_ibp_pkg"
        if ! bun install -g --ignore-scripts "$_ibp_pkg"; then
          echo "bun: 'bun install -g $_ibp_pkg' failed" >&2
          rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
        _ibp_bin="''${_ibp_pkg##*/}"
        if [ ! -f "$HOME/.bun/bin/$_ibp_bin" ] && \
           [ ! -f "$HOME/.bun/bin/$_ibp_bin.cmd" ]; then
          echo "bun: $_ibp_pkg installed but binary '$_ibp_bin' not found in '$HOME/.bun/bin'" >&2
          rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
          exit 1
        fi
        echo "bun: $_ibp_pkg installed successfully"
      done < "$_ibp_to_install"

      rm -f "$_ibp_desired" "$_ibp_installed" "$_ibp_to_remove" "$_ibp_to_install"
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
    installUvTools = lib.hm.dag.entryAfter [ "installBunPackages" ] ''
      set -eu

      _iut_uv_bin='${pkgs.uv}/bin/uv'

      # Declarative desired-state list.  One tool per line.
      # Add a PyPI package name here to install it; remove it to trigger
      # uninstall on the next apply.  Only add tools absent from nixpkgs and
      # cargo-binstall and bun (install preference: nixpkgs > cargo binstall > bun > uv).
      _iut_desired="$(mktemp)"
      # PaddleOCR: cross-platform OCR with GPU auto-detection.  uv for
      # cross-host version consistency (nixpkgs v3.5.0, PyPI v3.6.0).
      # Pinned to Python 3.11 via --python flag because its dependency
      # opencv-contrib-python cannot build on Python >=3.12 (distutils removed).
      printf '%s\n' 'paddleocr' >> "$_iut_desired"

      # Per-tool Python version requirements.  Empty string = use default.
      _iut_python_for_tool() {
        case "$1" in
          paddleocr) echo "3.11" ;;
          *) echo "" ;;
        esac
      }

      # Install required Python versions before attempting tool installs.
      # Stderr suppressed: uv emits a cosmetic "Failed to patch install name"
      # warning on macOS 15+ when installing older CPython that does not affect
      # functionality.  Real failures surface at tool-install time below.
      while IFS= read -r _iut_tool; do
        [ -z "$_iut_tool" ] && continue
        _iut_python=$(_iut_python_for_tool "$_iut_tool")
        [ -n "$_iut_python" ] && "$_iut_uv_bin" python install "$_iut_python" 2>/dev/null
      done < "$_iut_desired"

      # Get actually installed uv tools from `uv tool list` (zap-style: remove
      # any installed tool absent from the desired list, regardless of prior
      # managed state).  Parse only lines that match the documented
      # "name vX.Y.Z" shape so separator/header lines (for example "-")
      # cannot be misparsed as package names.
      _iut_installed="$(mktemp)"
      # undoc-supp: uv tool list may fail if no tool environment is initialised yet; treating the installed set as empty is correct — nothing to remove.
      "$_iut_uv_bin" tool list 2>/dev/null | ${pkgs.gawk}/bin/awk '/^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+v[0-9]/{print $1}' > "$_iut_installed" || true

      # Tools installed but not desired: zap-style removal.
      # Mirrors homebrew cleanup = "zap": removes anything installed but absent
      # from the declared desired set, regardless of how it was installed.
      _iut_to_remove="$(mktemp)"
      while IFS= read -r _iut_tool; do
        [ -z "$_iut_tool" ] && continue
        if ! grep -qxF "$_iut_tool" "$_iut_desired"; then
          printf '%s\n' "$_iut_tool" >> "$_iut_to_remove"
        fi
      done < "$_iut_installed"

      # Desired tools not yet installed according to `uv tool list`.
      _iut_to_install="$(mktemp)"
      while IFS= read -r _iut_tool; do
        [ -z "$_iut_tool" ] && continue
        if ! grep -qxF "$_iut_tool" "$_iut_installed"; then
          printf '%s\n' "$_iut_tool" >> "$_iut_to_install"
        fi
      done < "$_iut_desired"

      # Prune tools removed from the desired list.
      while IFS= read -r _iut_tool; do
        [ -z "$_iut_tool" ] && continue
        if ! printf '%s' "$_iut_tool" | ${pkgs.gnugrep}/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
          echo "uv: skipping invalid uninstall token '$_iut_tool'"
          continue
        fi
        echo "uv: uninstalling removed tool '$_iut_tool'"
        "$_iut_uv_bin" tool uninstall "$_iut_tool"
      done < "$_iut_to_remove"

      # Install additions.
      while IFS= read -r _iut_tool; do
        [ -z "$_iut_tool" ] && continue
        if ! printf '%s' "$_iut_tool" | ${pkgs.gnugrep}/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
          echo "uv: skipping invalid install token '$_iut_tool'"
          continue
        fi
        _iut_python=$(_iut_python_for_tool "$_iut_tool")
        if [ -n "$_iut_python" ]; then
          echo "uv: installing tool '$_iut_tool' with Python $_iut_python"
          "$_iut_uv_bin" tool install --no-build --python "$_iut_python" "$_iut_tool"
        else
          echo "uv: installing tool '$_iut_tool'"
          "$_iut_uv_bin" tool install --no-build "$_iut_tool"
        fi
      done < "$_iut_to_install"

      if [ ! -s "$_iut_to_install" ] && [ ! -s "$_iut_to_remove" ]; then
        echo "uv: all managed tools already converged — skipping"
      fi

      rm -f "$_iut_desired" "$_iut_installed" "$_iut_to_remove" "$_iut_to_install"
    '';

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
    initRustup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu
      ${agentHelpersSh}

      # Locate pkgs.rustup in the newly linked home-manager profile.  The
      # activation shell PATH has not yet been updated to reflect the profile, so
      # probe known profile bin directories in priority order.
      _nucleus_prepend_first_executable_dir rustup \
        "/etc/profiles/per-user/$USER/bin" \
        "/run/current-system/sw/bin" \
        "$HOME/.local/state/nix/profiles/profile/bin" \
        "$HOME/.nix-profile/bin" \
        "$HOME/.local/state/home-manager/profile/bin" \
        "$HOME/.local/home-manager/profile/bin" || true  # undoc-supp: rustup not in profile dir on first apply; fallback follows.

      if ! command -v rustup >/dev/null 2>&1; then
        echo "rustup: rustup not found after profile link; skipping initialization" >&2
      else
        # WHY none: forces every project to declare its toolchain via
        # rust-toolchain.toml; prevents silent use of a global stable and
        # matches Windows Invoke-RustupSetup.
        rustup default none
        echo "rustup: default toolchain set to none"

        # Install the stable toolchain so cargo +stable is available for
        # cargo-binstall compilation fallback and cargo install --list operations.
        # Mirrors Windows Invoke-RustupSetup desiredChannels=["stable"] behavior.
        if rustup toolchain list 2>/dev/null | grep -q "^stable"; then
          echo "rustup: stable toolchain already present"
        else
          echo "rustup: installing stable toolchain for cargo-binstall fallback"
          rustup toolchain install stable --no-self-update
        fi
      fi
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
    # Mirrors homebrew cleanup = "zap": removes anything installed but absent
    # from the declared desired set, regardless of how it was installed.
    #
    # Why after initRustup: cargo is provided by rustup's stable toolchain via
    # ~/.cargo/bin; initRustup ensures stable is installed before this step
    # invokes `cargo +stable` for list and uninstall operations.  Unified with
    # Windows Invoke-RustupSetup + Invoke-CargoBinstallSetup behavior.
    # -------------------------------------------------------------------------
    installCargoBinstallPackages = lib.hm.dag.entryAfter [ "initRustup" ] ''
      set -eu
      ${agentHelpersSh}

      # Declarative desired-state list.  On POSIX hosts this list is
      # intentionally empty because all managed Rust tools are provided by
      # nixpkgs (install preference: nixpkgs > cargo binstall > bun > uv).
      # Add a crate name here to install it via cargo-binstall if it is
      # truly absent from nixpkgs.
      _icp_desired="$(mktemp)"
      # No cargo-binstall-managed crates on POSIX.
      : > "$_icp_desired"

      # Probe ~/.cargo/bin (rustup shim location) first, then nix-profile /
      # home-manager-profile bin directories as fallback.  initRustup runs
      # before this step to ensure the stable toolchain is installed.
      _nucleus_prepend_first_executable_dir cargo \
        "$HOME/.cargo/bin" \
        "/etc/profiles/per-user/$USER/bin" \
        "/run/current-system/sw/bin" \
        "$HOME/.local/state/nix/profiles/profile/bin" \
        "$HOME/.nix-profile/bin" \
        "$HOME/.local/state/home-manager/profile/bin" \
        "$HOME/.local/home-manager/profile/bin" || true  # undoc-supp: cargo not in any profile dir; fallback follows.

      # Guard: cargo is provided by rustup (stable toolchain) via ~/.cargo/bin;
      # initRustup ensures stable is installed before this step runs.
      # If cargo is absent after PATH probing, skip rather than failing the
      # whole activation; nothing is installed by this step on POSIX hosts.
      if ! command -v cargo >/dev/null 2>&1; then
        echo "cargo-binstall: cargo not found in PATH; skipping package management"
        rm -f "$_icp_desired"
      else
        # Get actually installed crates from `cargo install --list` (zap-style).
        # Output format: "crate-name vX.Y.Z:" on header lines; extract the
        # crate name (first field) from lines matching that pattern.
        _icp_installed="$(mktemp)"
        # undoc-supp: cargo +stable install --list may fail if stable toolchain is missing or ~/.cargo is uninitialised; empty installed set is correct — nothing to remove.
        cargo +stable install --list 2>/dev/null | ${pkgs.gawk}/bin/awk '/^[a-zA-Z0-9_-]+ v/{print $1}' > "$_icp_installed" || true

        # Crates installed but not desired: zap-style removal.
        _icp_to_remove="$(mktemp)"
        while IFS= read -r _icp_crate; do
          [ -z "$_icp_crate" ] && continue
          if ! grep -qxF "$_icp_crate" "$_icp_desired"; then
            printf '%s\n' "$_icp_crate" >> "$_icp_to_remove"
          fi
        done < "$_icp_installed"

        # Desired crates not yet installed.
        _icp_to_install="$(mktemp)"
        while IFS= read -r _icp_crate; do
          [ -z "$_icp_crate" ] && continue
          if ! grep -qxF "$_icp_crate" "$_icp_installed"; then
            printf '%s\n' "$_icp_crate" >> "$_icp_to_install"
          fi
        done < "$_icp_desired"

        # Remove crates not in the desired list.
        while IFS= read -r _icp_crate; do
          [ -z "$_icp_crate" ] && continue
          echo "cargo-binstall: removing $_icp_crate"
          if ! cargo +stable uninstall "$_icp_crate"; then
            echo "cargo-binstall: 'cargo +stable uninstall $_icp_crate' failed" >&2
            rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
            exit 1
          fi
          echo "cargo-binstall: '$_icp_crate' removed"
        done < "$_icp_to_remove"

        # Install desired crates not currently installed.
        while IFS= read -r _icp_crate; do
          [ -z "$_icp_crate" ] && continue
          echo "cargo-binstall: installing $_icp_crate"
          if ! cargo-binstall --no-confirm "$_icp_crate"; then
            echo "cargo-binstall: 'cargo-binstall $_icp_crate' failed" >&2
            rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
            exit 1
          fi
          echo "cargo-binstall: '$_icp_crate' installed"
        done < "$_icp_to_install"

        if [ ! -s "$_icp_to_remove" ] && [ ! -s "$_icp_to_install" ]; then
          echo "cargo-binstall: all managed packages already converged — skipping"
        fi

        rm -f "$_icp_desired" "$_icp_installed" "$_icp_to_remove" "$_icp_to_install"
      fi
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
      set -eu

      _scs_jq_bin='${pkgs.jq}/bin/jq'
      ${agentHelpersSh}

      _scs_do_sync=true

      # Prepend ~/.bun/bin so the ClawHub binary installed by installBunPackages
      # is on PATH for this activation step.
      if [ -d "$HOME/.bun/bin" ]; then
        PATH="$HOME/.bun/bin:$PATH"
        export PATH
      fi

      # Resolve the repo root (same mechanism as agentsSymlink and agentsSkills).
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

      # Ensure ~/.agents/skills/ exists.  The agentsSkills activation creates
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
