# modules/editors.nix — Cross-platform editor configuration and VS Code symmetry.
#
# Source of truth for VS Code extensions and settings wiring lives here.
# Installation backend intentionally pivots by platform:
#   • Linux/NixOS: nixpkgs binaries
#   • macOS: backend selected in modules/core.nix (Homebrew or nixpkgs)
{ config, lib, pkgs, ... }:
let
  # Platform switch used to keep one declarative config while selecting the
  # backend that integrates best on each OS.
  isDarwin = pkgs.stdenv.isDarwin;

  # Parse the standalone JSON settings file during evaluation so invalid JSON
  # fails fast before activation touches user config paths.
  sharedSettings = builtins.fromJSON (builtins.readFile ./configs/vscode-settings.json);

  # Serialize once and reuse for all settings targets to guarantee byte-for-
  # byte parity between stable and insiders JSON files.
  sharedSettingsJson = builtins.toJSON sharedSettings;

  # Canonical extension set shared by both platforms.
  # On Linux, Home Manager installs these directly via programs.vscode.
  # On macOS, activation links Homebrew's expected extension path to a Nix-store
  # directory built from this same list.
  sharedExtensions = [
    pkgs.vscode-extensions.jnoortheen.nix-ide
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

  # OS-specific settings targets for stable and insiders channels.
  # Keeping both path computations here avoids drift between the two channels.
  codeSettingsRelPath =
    if isDarwin then "Library/Application Support/Code/User/settings.json"
    else ".config/Code/User/settings.json";

  insidersSettingsRelPath =
    if isDarwin then "Library/Application Support/Code - Insiders/User/settings.json"
    else ".config/Code - Insiders/User/settings.json";
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
    # When stable is Homebrew-managed, settings/extension sync is handled via
    # home.file + darwin bridge logic instead.
    enable = !isDarwin || !stableUsesHomebrew;
    package = pkgs.vscode;
    profiles.default.extensions = sharedExtensions;
  };

  # Write identical settings payloads for both Code channels using the
  # platform-specific user-data locations expected by each OS.
  home.file = {
    "${codeSettingsRelPath}".text = sharedSettingsJson;
    "${insidersSettingsRelPath}".text = sharedSettingsJson;
  };

  home.activation = lib.mkIf (isDarwin && needsDarwinExtensionBridge) {
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
