# MacBook/homebrew.nix - Homebrew package declarations for the MacBook host.
{
  config,
  lib,
  username,
  homebrew-core,
  homebrew-cask,
  openai-tools,
  smudge-smudge,
  ...
}:
let
  # Package overlap decisions are centralized in modules/core.nix.
  coreManagedBrews = config.nucleus.macos.homebrew.brews;
  coreManagedCasks = config.nucleus.macos.homebrew.casks;
  staticManagedBrews = [
    "openai/tools/softnet" # Runtime dependency of tart; must be declared to survive brew bundle --zap cleanup
    "openai/tools/tart" # macOS VM hypervisor using Apple Virtualization.framework (requires code-signed binary)
    "displayplacer" # CLI display arrangement tool
    "sqlite" # SQLite library; needed by qmd setCustomSQLite for sqlite-vec extension support
    "smudge/smudge/nightlight" # Night Shift schedule & temperature control
  ];

  managedBrews = builtins.sort (a: b: a < b) (lib.unique (staticManagedBrews ++ coreManagedBrews));

  # Dual-source casks (Google Chrome, VS Code, VLC) come from core.nix and are
  # merged below so backend switches stay centralized.
  # Google Gemini is not managed here: its global launcher competes with
  # Raycast and exposes no declarative preference key to reserve Option+Space.
  staticManagedCasks = [
    "alt-tab" # Windows-style alt-tab switcher
    "appcleaner" # Thorough app uninstaller
    "battery" # Apple Silicon charge-limit manager (maintains 80% cap)
    "blackhole-2ch" # Virtual audio driver for system-wide audio loopback (CamillaDSP capture)
    "betterdisplay" # Advanced display management and virtual screens
    "chrome-remote-desktop-host" # Headless remote-desktop receiver
    "coolterm" # Serial terminal
    "gimp" # Raster image editor; macOS-only cask (nixpkgs gimp is Linux-only)
    "google-chrome@canary" # Chrome dev channel for web testing
    "keka" # Graphical archiver with 7-Zip backend support
    "keyboardcleantool" # Blocks all keyboard and TouchBar input for cleaning
    "linearmouse" # Per-device mouse/trackpad scrolling behavior and sensitivity
    "lulu" # Outbound network firewall
    "macfuse@dev" # FUSE userspace driver for rclone and ntfs-3g mounts; the 5.4.0 dev channel is the first release built against the macOS 27 FSKit volume-operation APIs
    "middleclick" # Three/four-finger middle-click gesture helper
    "mounty" # NTFS auto-mounter for ntfs-3g drives
    "orbstack" # Docker/Linux VM runtime (faster than Docker Desktop)
    "parsec" # Low-latency remote gaming / desktop streaming
    "raycast" # Spotlight replacement and launcher
    "steam" # Game distribution and launcher platform
    "telegram-desktop@beta" # Telegram beta channel; kept static (no exact nixpkgs beta mapping)
    "whatsapp@beta" # WhatsApp pre-release client
  ];

  # QtPass goes to nixpkgs on macOS through
  # nucleus.packages.selection.backendOverrides in core.nix, because the cask
  # is not notarized. Windows uses WinGet IJHack.QtPass.
  managedCasks = builtins.sort (a: b: a < b) (lib.unique (staticManagedCasks ++ coreManagedCasks));
in
{

  # nix-homebrew pins the Homebrew binary and every tap definition through
  # flake.lock, so taps are declared here rather than derived from the packages.
  nix-homebrew = {
    enable = true;
    user = username;
    autoMigrate = true;
    mutableTaps = false;
    taps = {
      "homebrew/homebrew-core" = homebrew-core;
      "homebrew/homebrew-cask" = homebrew-cask;
      "openai/homebrew-tools" = openai-tools;
      "smudge/homebrew-smudge" = smudge-smudge;
    };
    trust = {
      # softnet is a transitive tart dependency that cannot be enumerated statically.
      taps = [ "openai/tools" ];
      formulae = [
        "smudge/smudge/nightlight"
      ];
    };
  };

  homebrew = {
    enable = true;

    onActivation.autoUpdate = false; # prevent network calls during activation
    onActivation.cleanup = "zap"; # remove unlisted formulae/casks and their data
    onActivation.upgrade = false; # prevent network calls during activation

    # WHY: --force: newer brew-bundle (Homebrew 4.x) requires --force when
    # --cleanup would uninstall packages unattended; activation runs under
    # sudo with no TTY to confirm.
    onActivation.extraFlags = [ "--force" ];

    taps = builtins.attrNames config.nix-homebrew.taps;
    brews = managedBrews;
    casks = managedCasks;

    # The managed user must be signed in to the App Store.
    masApps = {
      # Mac App Store only, so masApps is the only declarative install surface.
      Amphetamine = 937984704;
    };
  };
}
