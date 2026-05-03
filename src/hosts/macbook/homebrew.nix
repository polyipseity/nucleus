# macbook/homebrew.nix — Homebrew package declarations for the MacBook host.
#
# nix-darwin's homebrew module is the declarative bridge: on every activation
# it runs `brew bundle` from a generated Brewfile, then removes any formula/cask
# not listed here (cleanup = "zap" also removes app data).
{ pkgs, ... }:
let
  # CLI formulae managed via Homebrew.
  # These are tools unavailable in nixpkgs or where the Homebrew build is
  # preferred (e.g. tightly coupled to macOS internals).
  managedBrews = [
    "displayplacer"              # CLI display arrangement tool
    "smudge/smudge/nightlight"   # Night Shift schedule & temperature control
    "zackelia/formulae/bclm"     # Battery charge limit management
  ];

  # GUI applications managed via Homebrew Cask.
  managedCasks = [
    "alt-tab"                    # Windows-style alt-tab switcher
    "appcleaner"                 # Thorough app uninstaller
    "betterdisplay"              # Advanced display management and virtual screens
    "chrome-remote-desktop-host" # Headless remote-desktop receiver
    "coolterm"                   # Serial terminal
    "discord@canary"             # Discord pre-release client
    "google-chrome"              # Primary browser
    "google-chrome@canary"       # Chrome dev channel for web testing
    "iterm2"                     # Terminal emulator
    "lulu"                       # Outbound network firewall
    "obsidian"                   # Note-taking / knowledge base
    "orbstack"                   # Docker/Linux VM runtime (faster than Docker Desktop)
    "parsec"                     # Low-latency remote gaming / desktop streaming
    "raycast"                    # Spotlight replacement and launcher
    "rectangle"                  # Window snapping
    "stats"                      # Menu bar system stats
    "telegram-desktop@beta"      # Telegram pre-release client
    "utm"                        # QEMU-based VM manager
    "visual-studio-code"         # VS Code stable
    "visual-studio-code@insiders" # VS Code Insiders (pre-release)
    "vlc"                        # Media player
    "whatsapp@beta"              # WhatsApp pre-release client
  ];

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
