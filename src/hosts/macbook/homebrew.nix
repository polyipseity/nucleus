{ pkgs, ... }:
let
  managedBrews = [
    "displayplacer"
    "smudge/smudge/nightlight"
    "zackelia/formulae/bclm"
  ];

  managedCasks = [
    "alt-tab"
    "appcleaner"
    "betterdisplay"
    "chrome-remote-desktop-host"
    "coolterm"
    "discord@canary"
    "google-chrome"
    "google-chrome@canary"
    "iterm2"
    "lulu"
    "obsidian"
    "orbstack"
    "parsec"
    "raycast"
    "rectangle"
    "stats"
    "telegram-desktop@beta"
    "utm"
    "visual-studio-code"
    "visual-studio-code@insiders"
    "vlc"
    "whatsapp@beta"
  ];

  managedSystemPackages = [
    (pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ]))
  ];

  extractTap = item:
    let
      matches = builtins.match "(.*)/[^/]+" item;
    in
    if matches == null then null else builtins.elemAt matches 0;

  defaultTaps = [ "homebrew/cask" "homebrew/core" ];

  allTaps =
    let
      rawTaps = builtins.filter (x: x != null) (map extractTap (managedBrews ++ managedCasks));
      filtered = builtins.filter (tap: !(builtins.elem tap defaultTaps)) rawTaps;
    in
    builtins.foldl' (acc: tap: if builtins.elem tap acc then acc else acc ++ [ tap ]) [ ] filtered;
in
{
  environment.systemPackages = managedSystemPackages;

  homebrew = {
    enable = true;

    onActivation.autoUpdate = true;
    onActivation.cleanup = "zap";
    onActivation.upgrade = true;

    taps = allTaps;
    brews = managedBrews;
    casks = managedCasks;
  };
}
