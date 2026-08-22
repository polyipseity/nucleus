# MacBook/homebrew.nix — Homebrew package declarations for the MacBook host.
#
# nix-darwin's homebrew module is the declarative bridge: on every activation
# it runs `brew bundle` from a generated Brewfile, then removes any formula/cask
# not listed here (cleanup = "zap" also removes app data).
{
  config,
  lib,
  username,
  homebrew-core,
  homebrew-cask,
  cirruslabs-cli,
  macos-fuse-t-cask,
  smudge-smudge,
  zackelia-formulae,
  ...
}:
let
  # Package overlap decisions are centralized in modules/core.nix.
  coreManagedBrews = config.nucleus.macos.homebrew.brews;
  coreManagedCasks = config.nucleus.macos.homebrew.casks;

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
    "blackhole-2ch" # Virtual audio driver for system-wide audio loopback (CamillaDSP capture)
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
    "mounty" # NTFS auto-mounter for fuse-t drives
    "orbstack" # Docker/Linux VM runtime (faster than Docker Desktop)
    "parsec" # Low-latency remote gaming / desktop streaming
    "raycast" # Spotlight replacement and launcher
    "steam" # Game distribution and launcher platform
    "telegram-desktop@beta" # Telegram beta channel; kept static (no exact nixpkgs beta mapping)
    "whatsapp@beta" # WhatsApp pre-release client
  ];

  # QtPass (GUI frontend for pass/gopass) is routed to nixpkgs on macOS via
  # nucleus.packages.selection.backendOverrides in core.nix (the Homebrew cask
  # is broken/notarized), so it is contributed by core.nix's managedNixPackages
  # rather than listed here. Windows uses WinGet IJHack.QtPass.
  managedCasks = builtins.sort (a: b: a < b) (lib.unique (staticManagedCasks ++ coreManagedCasks));

  # Nix-managed packages that must be in the system environment (not just the
  # user profile) because they need to be reachable from non-login shells or
  # other accounts. CLI tools default to nixpkgs per AGENTS.md policy.
  # pass.withExtensions wraps pkgs.pass (pass-otp is an output of pass, not a
  # top-level attr), so it is contributed via core.nix's extraSystemPackages
  # rather than a managedPackages entry.
in
{

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
      "macos-fuse-t/homebrew-cask" = macos-fuse-t-cask;
      "smudge/homebrew-smudge" = smudge-smudge;
      "zackelia/homebrew-formulae" = zackelia-formulae;
    };
    trust = {
      # Trust cirruslabs/cli as a whole tap because softnet is a transitive
      # dependency of tart that cannot be enumerated statically.
      taps = [ "cirruslabs/cli" ];
      formulae = [
        "smudge/smudge/nightlight"
        "zackelia/formulae/bclm"
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

    # Derive tap names from nix-homebrew config, which pins each tap's
    # git commit via flake.lock.
    taps = builtins.attrNames config.nix-homebrew.taps;
    brews = managedBrews;
    casks = managedCasks;

    # Mac App Store apps managed via brew bundle's `mas` stanza.
    # Requires the managed user to be signed in to the App Store.
    masApps = {
      # Amphetamine is Mac App Store-only; masApps is the canonical declarative
      # install surface in nix-darwin's Homebrew bridge for this host.
      Amphetamine = 937984704;
    };
  };
}
