# modules/fonts.nix — Open-source typography baseline shared across POSIX hosts.
#
# Provides one declarative font source-of-truth for Latin and CJK workflows.
# All selected families are open-source so host parity does not depend on
# proprietary system fonts that vary by platform image.
{ lib, options, pkgs, ... }:
let
  # Canonical open-source font package set used by both macOS and Linux.
  # - Inter: modern sans-serif for UI/document reading.
  # - JetBrains Mono: high-legibility coding monospace.
  # - Nerd Fonts patch for JetBrains Mono: terminal iconography parity.
  # - Source Serif: readable open-source serif family.
  # - Noto CJK Sans/Serif: unified Simplified + Traditional Chinese coverage.
  openSourceFontPackages = [
    pkgs.inter
    pkgs.jetbrains-mono
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts-cjk-serif
    pkgs.source-serif
  ];

  # Aggregate all selected font packages into one immutable store path so macOS
  # can consume a stable directory symlink under ~/Library/Fonts.
  darwinFontStore = pkgs.symlinkJoin {
    name = "open-source-fonts";
    paths = openSourceFontPackages;
  };
in
{
  config = lib.mkMerge [
    {
      home.packages = openSourceFontPackages;

      home.file = lib.optionalAttrs pkgs.stdenv.isDarwin {
        # macOS app frameworks discover user fonts in ~/Library/Fonts. Linking
        # this directory to the Nix-managed aggregate keeps typography
        # declarative while avoiding per-font imperative installs.
        "Library/Fonts/nucleus-open-source".source = "${darwinFontStore}/share/fonts";
      };
    }

    # Linux apps resolve fonts through fontconfig; enabling it keeps the
    # selected open-source families authoritative for CLI/GUI rendering parity.
    # defaultFonts sets explicit priority so generic family queries (sans-serif,
    # serif, monospace) resolve to our open-source baseline rather than
    # whatever fontconfig picks by heuristic.  Noto CJK variants follow the
    # Latin families so Latin characters use the canonical family and CJK
    # characters fall through to the correct locale-specific Noto variant.
    (lib.optionalAttrs (options ? fonts && options.fonts ? fontconfig) {
      fonts.fontconfig.enable = true;
      fonts.fontconfig.defaultFonts = {
        monospace = [
          # JetBrainsMono Nerd Font Mono is the narrowed variant from the NF
          # package; it preserves cell-width expectations in terminal emulators
          # while adding icon glyphs.
          "JetBrainsMono Nerd Font Mono"
          # Noto Sans Mono CJK provides monospace-metric CJK glyphs so CJK
          # characters inside a terminal do not fall back to a proportional face.
          "Noto Sans Mono CJK SC"
          "Noto Sans Mono CJK TC"
        ];
        sansSerif = [
          "Inter"
          "Noto Sans CJK SC"
          "Noto Sans CJK TC"
        ];
        serif = [
          "Source Serif 4"
          "Noto Serif CJK SC"
          "Noto Serif CJK TC"
        ];
      };
    })
  ];
}
