# macbook/homebrew.nix — Homebrew package declarations for the MacBook host.
#
# nix-darwin's homebrew module is the declarative bridge: on every activation
# it runs `brew bundle` from a generated Brewfile, then removes any formula/cask
# not listed here (cleanup = "zap" also removes app data).
{ config, lib, pkgs, ... }:
let
  # Package overlap decisions are centralized in modules/core.nix.
  coreManagedBrews = config.nucleus.macos.generatedHomebrew.brews;
  coreManagedCasks = config.nucleus.macos.generatedHomebrew.casks;

  # CLI formulae managed via Homebrew.
  # These are tools unavailable in nixpkgs or where the Homebrew build is
  # preferred (e.g. tightly coupled to macOS internals).
  staticManagedBrews = [
    "displayplacer"              # CLI display arrangement tool
    "p7zip"                      # 7-Zip archive extraction and compression CLI
    "smudge/smudge/nightlight"   # Night Shift schedule & temperature control
    "zackelia/formulae/bclm"     # Battery charge limit management
  ];

  managedBrews = builtins.sort (a: b: a < b) (lib.unique (staticManagedBrews ++ coreManagedBrews));

  # GUI applications managed via Homebrew Cask.
  # Dual-source casks (for example Google Chrome, VS Code, VLC) are selected
  # from core.nix and merged below so backend switches stay centralized.
   staticManagedCasks = [
     "alt-tab"                    # Windows-style alt-tab switcher
     "appcleaner"                 # Thorough app uninstaller
     "battery"                    # Apple Silicon charge-limit manager (maintains 80% cap)
     "betterdisplay"              # Advanced display management and virtual screens
     "chrome-remote-desktop-host" # Headless remote-desktop receiver
     "coolterm"                   # Serial terminal
     "google-chrome@canary"       # Chrome dev channel for web testing
     "keka"                       # Graphical archiver with 7-Zip backend support
     "lulu"                       # Outbound network firewall
     "orbstack"                   # Docker/Linux VM runtime (faster than Docker Desktop)
     "parsec"                     # Low-latency remote gaming / desktop streaming
     "raycast"                    # Spotlight replacement and launcher
     "telegram-desktop@beta"      # Telegram beta channel; kept static (no exact nixpkgs beta mapping)
     "whatsapp@beta"              # WhatsApp pre-release client
   ];

  managedCasks = builtins.sort (a: b: a < b) (lib.unique (staticManagedCasks ++ coreManagedCasks));

  # Nix-managed packages that must be in the system environment (not just the
  # user profile) because they need to be reachable from non-login shells or
  # other accounts.
  managedSystemPackages = [
    (pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ]))
  ];

  # Extract the tap name from a fully qualified formula/cask reference such as
  # "owner/repo/formula".  Returns null for unqualified names like "git".
  extractTap = item:
    let
      matches = builtins.match "(.*)/[^/]+" item;
    in
    if matches == null then null else builtins.elemAt matches 0;

  # Taps bundled with every Homebrew installation; no explicit `tap` entry needed.
  defaultTaps = [ "homebrew/cask" "homebrew/core" ];

  # Derive the unique set of non-default taps referenced by any brew or cask entry.
  allTaps =
    let
      rawTaps = builtins.filter (x: x != null) (map extractTap (managedBrews ++ managedCasks));
      filtered = builtins.filter (tap: !(builtins.elem tap defaultTaps)) rawTaps;
    in
    # Deduplicate while preserving order.
    builtins.foldl' (acc: tap: if builtins.elem tap acc then acc else acc ++ [ tap ]) [ ] filtered;
in
{
  environment.systemPackages = managedSystemPackages;

  homebrew = {
    enable = true;

    onActivation.autoUpdate = true;   # refresh Homebrew itself before bundling
    onActivation.cleanup = "zap";     # remove unlisted formulae/casks and their data
    onActivation.upgrade = true;      # upgrade outdated formulae/casks automatically

    taps = allTaps;
    brews = managedBrews;
    casks = managedCasks;
  };
}
