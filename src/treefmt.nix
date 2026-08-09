# src/treefmt.nix — treefmt formatter multiplexer configuration.
#
# treefmt-nix module imported by flake.nix via mkWrapper.
# Configures which formatters are enabled and their settings.
#
# Enabled: nixfmt, deadnix, yamllint, shellcheck, shfmt, taplo, packer,
#          actionlint, pinact, zizmor
# Disabled: mdformat, typos (see WHY in programs)

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

    shfmt = {
      enable = true;
      useEditorConfig = true;
    };
    taplo.enable = true;
    packer.enable = true;
    actionlint.enable = true;
    pinact = {
      enable = true;
      update = false; # WHY: pre-commit must not hit GitHub API or bump action versions
      verify = false; # WHY: offline check uses --no-api instead of --verify
    };
    zizmor.enable = true;

    # WHY: fights markdownlint + prek whitespace hooks; authoring policy forbids hard-wrap reflow
    mdformat.enable = false;
    # WHY: high false-positive rate on domain terms, secrets blobs, and vendored symbol lists
    typos.enable = false;
  };

  settings.formatter.pinact.options = [
    "--fix=false"
    "--no-api"
  ];

  settings.excludes = [
    # discord-music-rpc app writes its config only when the schema needs
    # migration (diff-driven, stat-cached), so treefmt should not touch the
    # managed file — it only manages files that the project owns exclusively.
    "src/users/*/discord-music-rpc/config.yaml"
    "vendor/**"
  ];
}
