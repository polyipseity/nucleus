# MacBook/homebrew.nix — Homebrew package declarations for the MacBook host.
#
# nix-darwin's homebrew module is the declarative bridge: on every activation
# it runs `brew bundle` from a generated Brewfile, then removes any formula/cask
# not listed here (cleanup = "zap" also removes app data).
{
  config,
  lib,
  pkgs,
  username,
  homebrew-core,
  homebrew-cask,
  cirruslabs-cli,
  smudge-smudge,
  zackelia-formulae,
  ...
}:
let
  # Package overlap decisions are centralized in modules/core.nix.
  coreManagedBrews = config.nucleus.macos.generatedHomebrew.brews;
  coreManagedCasks = config.nucleus.macos.generatedHomebrew.casks;

  # CLI formulae managed via Homebrew.
  # These are tools unavailable in nixpkgs or where the Homebrew build is
  # preferred (e.g. tightly coupled to macOS internals).
  staticManagedBrews = [
    "cirruslabs/cli/tart" # macOS VM hypervisor using Apple Virtualization.framework (requires code-signed binary)
    "displayplacer" # CLI display arrangement tool
    "smudge/smudge/nightlight" # Night Shift schedule & temperature control
    "zackelia/formulae/bclm" # Battery charge limit management
  ];

  managedBrews = builtins.sort (a: b: a < b) (lib.unique (staticManagedBrews ++ coreManagedBrews));

  # GUI applications managed via Homebrew Cask.
  # Dual-source casks (for example Google Chrome, VS Code, VLC) are selected
  # from core.nix and merged below so backend switches stay centralized.
  # Google Gemini is intentionally not managed on macOS: its global launcher
  # competes with Raycast, and the app does not expose a stable declarative
  # preference key we can enforce to reserve Option+Space for Raycast only.
  staticManagedCasks = [
    "alt-tab" # Windows-style alt-tab switcher
    "appcleaner" # Thorough app uninstaller
    "battery" # Apple Silicon charge-limit manager (maintains 80% cap)
    "betterdisplay" # Advanced display management and virtual screens
    "chrome-remote-desktop-host" # Headless remote-desktop receiver
    "coolterm" # Serial terminal
    "fuse-t" # FSKit-capable FUSE userspace driver for rclone mounts
    "gimp" # Raster image editor; macOS-only cask (nixpkgs gimp is Linux-only)
    "google-chrome@canary" # Chrome dev channel for web testing
    "keka" # Graphical archiver with 7-Zip backend support
    "keyboardcleantool" # Blocks all keyboard and TouchBar input for cleaning
    "linearmouse" # Per-device mouse/trackpad scrolling behavior and sensitivity
    "lulu" # Outbound network firewall
    "middleclick" # Three/four-finger middle-click gesture helper
    "orbstack" # Docker/Linux VM runtime (faster than Docker Desktop)
    "parsec" # Low-latency remote gaming / desktop streaming
    "raycast" # Spotlight replacement and launcher
    "steam" # Game distribution and launcher platform
    "telegram-desktop@beta" # Telegram beta channel; kept static (no exact nixpkgs beta mapping)
    "whatsapp@beta" # WhatsApp pre-release client
  ];

  # QtPass (GUI frontend for pass/gopass) is intentionally absent from macOS
  # Homebrew. The Homebrew cask fails Gatekeeper checks (app not notarized) and
  # is scheduled for removal in September 2026. Use pass from the CLI or the
  # nixpkgs-based qtpass (added to managedSystemPackages below). Windows uses
  # WinGet IJHack.QtPass.
  managedCasks = builtins.sort (a: b: a < b) (lib.unique (staticManagedCasks ++ coreManagedCasks));

  # Nix-managed packages that must be in the system environment (not just the
  # user profile) because they need to be reachable from non-login shells or
  # other accounts. CLI tools default to nixpkgs per AGENTS.md policy; qtpass
  # is included here as a fallback since the Homebrew cask is broken.
  managedSystemPackages = [
    pkgs.qtpass
    (pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ]))
  ];
in
{
  environment.systemPackages = managedSystemPackages;

  # nix-homebrew pins Homebrew binary and all tap definitions via flake.lock,
  # making Homebrew fully declarative and supply-chain hardened.
  # Taps are derived from here rather than auto-derived from package lists.
  nix-homebrew = {
    enable = true;
    user = username;
    autoMigrate = true;
    mutableTaps = false;
    taps = {
      "homebrew/homebrew-core" = homebrew-core;
      "homebrew/homebrew-cask" = homebrew-cask;
      "cirruslabs/homebrew-cli" = cirruslabs-cli;
      "smudge/homebrew-smudge" = smudge-smudge;
      "zackelia/homebrew-formulae" = zackelia-formulae;
    };
  };

  homebrew = {
    enable = true;

    onActivation.autoUpdate = false; # prevent network calls during activation
    onActivation.cleanup = "zap"; # remove unlisted formulae/casks and their data
    onActivation.upgrade = false; # prevent network calls during activation

    # WHY --force: newer brew-bundle (Homebrew 4.x) requires --force when
    # --cleanup would uninstall packages unattended; activation runs under
    # sudo with no TTY to confirm.
    onActivation.extraFlags = [ "--force" ];

    # Derive tap names from nix-homebrew config, which pins each tap's
    # git commit via flake.lock.
    taps = builtins.attrNames config.nix-homebrew.taps;
    brews = managedBrews;
    casks = managedCasks;

    # Provision full Xcode from the Mac App Store via brew bundle's `mas` stanza.
    # Requires the managed user to be signed in to the App Store.
    masApps = {
      # Amphetamine is Mac App Store-only; masApps is the canonical declarative
      # install surface in nix-darwin's Homebrew bridge for this host.
      Amphetamine = 937984704;
      Xcode = 497799835;
    };
  };
}
