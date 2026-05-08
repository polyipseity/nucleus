# modules/editors.nix — Cross-platform editor configuration and VS Code symmetry.
#
# Source of truth for VS Code extensions and config wiring lives here.
# Installation backend intentionally pivots by platform:
#   • Linux/NixOS: nixpkgs binaries
#   • macOS: backend selected in modules/core.nix (Homebrew or nixpkgs)
#
# VS Code config files (settings, keybindings, MCP, tasks, snippets, prompts,
# profiles, and Copilot Chat memory) are kept as live repo files under
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
    # Files managed: settings.json, keybindings.json, mcp.json, tasks.json.
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
        ensure_file_symlink "$_vsym_config_dir/keybindings.json" "$_vsym_base_dir/keybindings.json"
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
    # while Nix-managed extensions live in the store. Keep both app channels in
    # sync by replacing those mutable directories with symlinks to the single
    # Nix-store extension tree derived from sharedExtensions above.
    # -----------------------------------------------------------------------
    vscodeDarwinExtensionBridge = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      source_extensions='${darwinExtensionStore}/share/vscode/extensions'
      stable_extensions="$HOME/.vscode/extensions"
      insiders_extensions="$HOME/.vscode-insiders/extensions"

      ${lib.optionalString stableUsesHomebrew ''
      mkdir -p "$HOME/.vscode"

      if [ -L "$stable_extensions" ] || [ -e "$stable_extensions" ]; then
        rm -rf "$stable_extensions"
      fi

      ln -s "$source_extensions" "$stable_extensions"
      ''}

      ${lib.optionalString insidersUsesHomebrew ''
      mkdir -p "$HOME/.vscode-insiders"

      if [ -L "$insiders_extensions" ] || [ -e "$insiders_extensions" ]; then
        rm -rf "$insiders_extensions"
      fi

      ln -s "$source_extensions" "$insiders_extensions"
      ''}
    '';
  };
}
