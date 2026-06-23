# Open-source font baseline shared across POSIX hosts.
{
  lib,
  options,
  pkgs,
  ...
}:
let
  openSourceFontPackages = [
    pkgs.inter
    pkgs.jetbrains-mono
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts-cjk-serif
    pkgs.source-serif
  ];

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
        "Library/Fonts/open-source-fonts".source = "${darwinFontStore}/share/fonts";
      };
    }

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
