# src/treefmt.nix — treefmt formatter multiplexer configuration.
#
# treefmt-nix module imported by flake.nix via mkWrapper.
# Configures which formatters are enabled and their settings.
#
# Enabled: nixfmt, deadnix, yamllint, shellcheck
# Available but disabled (uncomment to enable):
#   shfmt   — Shell script formatting
#   mdformat — Markdown formatting
#   taplo   — TOML formatting
#   typos   — Spell checker
#   actionlint — GitHub Actions workflow linting
#   pinact  — Pin GitHub Actions to commit hashes
#   zizmor  — GitHub Actions security scanner

{ ... }:
{
  projectRootFile = "src/flake.nix";

  programs = {
    nixfmt.enable = true;
    deadnix.enable = true;
    yamllint.enable = true;
    shellcheck = {
      enable = true;
      # resolves `# shellcheck source=` directives relative to each script's directory
      source-path = "SCRIPTDIR";
      # follow external sourced files (required for source-path to work)
      external-sources = true;
      # Explicitly enforce the lowest severity so ALL findings fail the build.
      severity = "style";
    };

    # Additional formatters (all explicitly disabled — enable by flipping to true):
    shfmt.enable = false; # Shell script formatting
    mdformat.enable = false; # Markdown formatting
    taplo.enable = false; # TOML formatting
    typos.enable = false; # Spell checker
    actionlint.enable = false; # GitHub Actions workflow linting
    pinact.enable = false; # Pin GitHub Actions to commit hashes
    zizmor.enable = false; # GitHub Actions security scanner
  };

  settings.excludes = [
    "vendor/**"
    # discord-music-rpc app rewrites its own config on startup (writable
    # symlink to the repo file).  treefmt should not touch app-managed
    # files — it only manages files that the project owns exclusively.
    "src/modules/configs/discord-music-rpc/config.yaml"
  ];
}
