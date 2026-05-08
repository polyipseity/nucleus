# modules/editors.nix — Cross-platform editor configuration and VS Code symmetry.
#
# Source of truth for VS Code extensions and config wiring lives here.
# Installation backend intentionally pivots by platform:
#   • Linux/NixOS: nixpkgs binaries
#   • macOS: backend selected in modules/core.nix (Homebrew or nixpkgs)
#
# VS Code config files (settings, per-host keybindings, MCP, tasks, snippets,
# prompts, profiles, and Copilot Chat memory) are kept as live repo files under
# src/modules/configs/vscode/ so that every VS Code write appears as an
# unstaged git change.  The vscodeSymlinks activation creates symlinks from
# the per-channel User/ directories to those repo files at apply time.
{ config, lib, pkgs, ... }:
let
  # Platform switch used to keep one declarative config while selecting the
  # backend that integrates best on each OS.
  isDarwin = pkgs.stdenv.isDarwin;

  # Canonical extension set shared by both platforms.
  # On Linux, Home Manager installs these directly via programs.vscode.
  # On macOS, activation links Homebrew's expected extension path to a Nix-store
  # directory built from this same list.
  sharedExtensions = [
    pkgs.vscode-extensions.jnoortheen.nix-ide
    pkgs.vscode-extensions.myriad-dreamin.tinymist
    pkgs.vscode-extensions.rust-lang.rust-analyzer
    pkgs.vscode-extensions.tamasfe.even-better-toml
  ];

  # Materialize the extension list under a deterministic Nix-store directory so
  # Darwin Homebrew app bundles can consume the exact same extension payload.
  darwinExtensionStore = pkgs.symlinkJoin {
    name = "nucleus-vscode-extensions";
    paths = sharedExtensions;
  };

  # On Darwin, core.nix computes overlap-package backend routing and exposes
  # the selected Homebrew casks here. editors.nix consumes that resolved output
  # so VS Code behavior follows one canonical backend decision path.
  darwinManagedCasks =
    if isDarwin then config.nucleus.macos.generatedHomebrew.casks else [ ];

  # Channel-specific backend resolution derived from core.nix output.
  stableUsesHomebrew = builtins.elem "visual-studio-code" darwinManagedCasks;
  insidersUsesHomebrew = builtins.elem "visual-studio-code@insiders" darwinManagedCasks;

  # Bridge only the channels currently routed to Homebrew.
  needsDarwinExtensionBridge = stableUsesHomebrew || insidersUsesHomebrew;

  # Per-channel User data directories referenced by the vscodeSymlinks activation.
  # These are shell strings whose $HOME is intentionally left unexpanded so the
  # activation script evaluates them at runtime with the actual home directory.
  stableBaseDir =
    if isDarwin then "$HOME/Library/Application Support/Code/User"
    else "$HOME/.config/Code/User";

  insidersBaseDir =
    if isDarwin then "$HOME/Library/Application Support/Code - Insiders/User"
    else "$HOME/.config/Code - Insiders/User";

  # Select the per-host keybindings source file so that platform-specific
  # shortcuts (Cmd on macOS vs Ctrl on NixOS/Linux) are tracked independently
  # without cross-host pollution in a shared repo file.
  vscodeKeybindingsFile =
    if isDarwin then "keybindings.mac.json"
    else "keybindings.nixos.json";
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

  # Keep VS Code binaries in nixpkgs on non-Darwin systems. On Darwin, package
  # installation backend is selected in core.nix and must not be duplicated
  # here, or backend overrides would diverge between modules.
  home.packages = lib.optionals (!isDarwin) [
    pkgs.vscode
    pkgs.vscode-insiders
  ];

  programs.vscode = {
    # Enable native Home Manager integration whenever stable VS Code is routed
    # to nixpkgs (all non-Darwin hosts and Darwin override-to-nixpkgs cases).
    # When stable is Homebrew-managed, extension sync is handled via the
    # Darwin bridge activation instead.
    enable = !isDarwin || !stableUsesHomebrew;
    package = pkgs.vscode;
    profiles.default.extensions = sharedExtensions;
  };

  home.activation = {
    # -------------------------------------------------------------------------
    # vscodeSymlinks
    # Replaces VS Code's per-channel config files with symlinks into the live
    # repo tree (src/modules/configs/vscode/) so that every VS Code write
    # (settings change, keybinding edit, MCP server addition, Copilot memory)
    # appears immediately as an unstaged git diff.
    #
    # Files managed: settings.json, keybindings.<host>.json (linked as
    #   keybindings.json), mcp.json, tasks.json.
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
    vscodeSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
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
        echo "nucleus: vscodeSymlinks: repo root not set; run via apply.sh or export NUCLEUS_REPO." >&2
        exit 1
      fi

      _vsym_config_dir="$_vsym_repo_root/src/modules/configs/vscode"
      if [ ! -d "$_vsym_config_dir" ]; then
        echo "nucleus: vscodeSymlinks: config dir not found: $_vsym_config_dir" >&2
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
        ensure_file_symlink "$_vsym_config_dir/${vscodeKeybindingsFile}" "$_vsym_base_dir/keybindings.json"
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
  } // lib.optionalAttrs (isDarwin && needsDarwinExtensionBridge) {
    # -----------------------------------------------------------------------
    # vscodeDarwinExtensionBridge
    # Homebrew VS Code reads extensions from ~/.vscode{,-insiders}/extensions,
    # while Nix-managed extensions live in the Nix store.  The directory must
    # remain a real writable path (not a symlink to the store) because VS Code
    # writes extensions.json inside it at startup; a whole-directory symlink
    # to the immutable store causes EACCES.  Instead, keep a real writable
    # directory and populate it with per-extension symlinks into the store.
    # -----------------------------------------------------------------------
    vscodeDarwinExtensionBridge = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      source_extensions='${darwinExtensionStore}/share/vscode/extensions'
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
      #   3. Remove stale per-extension symlinks whose source entry no longer
      #      exists (extension removed from the Nix manifest).
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

        # Step 3: remove stale symlinks for extensions removed from the Nix manifest.
        # Use bare-star glob (no trailing /) to catch broken symlinks as well.
        for _sed_existing in "$_sed_dir"/*; do
          # Only process symlinks; real files/dirs are user-installed, leave them.
          [ -L "$_sed_existing" ] || continue
          _sed_ext_name="''${_sed_existing##*/}"
          [ -e "$source_extensions/$_sed_ext_name" ] && continue
          rm "$_sed_existing"
        done
      }

      ${lib.optionalString stableUsesHomebrew ''
      mkdir -p "$HOME/.vscode"
      setup_extension_dir "$stable_extensions"
      ''}

      ${lib.optionalString insidersUsesHomebrew ''
      mkdir -p "$HOME/.vscode-insiders"
      setup_extension_dir "$insiders_extensions"
      ''}
    '';
  };
}
