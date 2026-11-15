# MacBook/homebrew.nix - Homebrew package declarations for the MacBook host.
{
  config,
  lib,
  username,
  homebrew-core,
  homebrew-cask,
  openai-tools,
  cirruslabs-cli,
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
    "fuse-t" # kext-free FUSE library rclone loads on macOS 27; mounts through a local NFSv4 server with no file system extension to approve (macFUSE's FSKit enablement kept reverting, 2026-10-14)
    "gimp" # Raster image editor; macOS-only cask (nixpkgs gimp is Linux-only)
    "google-chrome@canary" # Chrome dev channel for web testing
    "keka" # Graphical archiver with 7-Zip backend support
    "keyboardcleantool" # Blocks all keyboard and TouchBar input for cleaning
    "linearmouse" # Per-device mouse/trackpad scrolling behavior and sensitivity
    "lulu" # Outbound network firewall
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

  # WHY: Homebrew 7.0.13 on macOS 27 requires the selected developer directory
  # to identify as Xcode >= 27.0 when `xcode-select -print-path` resolves a
  # non-CLT path. `nucleus-apply` intentionally switches xcode-select to the Nix
  # apple-sdk-enhanced tree (no CLT, no Xcode version.plist/xcodebuild) for the
  # managed toolchain, so Homebrew misreads it as an installed-but-outdated
  # Xcode and blocks `brew bundle` (e.g. openai/tools/softnet, tart). Homebrew
  # reads the active developer dir via `/usr/bin/xcode-select -print-path` (not
  # DEVELOPER_DIR / HOMEBREW_DEVELOPER_DIR), so we hide Xcode only for the bundle
  # command by resetting xcode-select to its CLT-default state. With CLT absent
  # and no Xcode.app, Homebrew does not see an installed Xcode and therefore does
  # not apply the Xcode-minimum gate. The previous developer dir is restored on
  # success or failure. We do not fake an Xcode version, because that would have
  # to track Homebrew’s minimum and could mislead other consumers.
  brewBundleWithoutSelectedXcode = body: ''
    _nucleus_xs_saved="$(/usr/bin/xcode-select -print-path 2>/dev/null || true)" # check-suppress:suppression_doc: no selected developer dir means there is nothing to restore
    _nucleus_restore_xcode_select() {
      if [ -n "$_nucleus_xs_saved" ]; then
        if ! /usr/bin/xcode-select --switch "$_nucleus_xs_saved" >/dev/null 2>&1; then
          echo >&2 "warning: failed to restore xcode-select developer dir to $_nucleus_xs_saved"
        fi
      else
        /usr/bin/xcode-select --reset >/dev/null 2>&1 || true # check-suppress:suppression_doc: reset best-effort when no previous developer dir was recorded
      fi
    }
    trap _nucleus_restore_xcode_select EXIT
    /usr/bin/xcode-select --reset >/dev/null 2>&1 || true # check-suppress:suppression_doc: reset may fail on unsupported systems; brew bundle still runs and previous state is restored
    set +e
    ${body}
    _nucleus_brew_bundle_status=$?
    set -e
    _nucleus_restore_xcode_select
    trap - EXIT
    (exit "$_nucleus_brew_bundle_status")
  '';
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
      "cirruslabs/homebrew-cli" = cirruslabs-cli;
      "smudge/homebrew-smudge" = smudge-smudge;
    };
    trust = {
      # softnet is a transitive tart dependency that cannot be enumerated statically.
      taps = [
        "openai/tools"
        "cirruslabs/cli"
      ];
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

  # WHY: wrap the generated brew-bundle invocation so Homebrew runs while
  # xcode-select points at an absent CLT path (no selected Xcode, CLT still
  # absent) instead of the Nix apple-sdk-enhanced dev dir. This preserves the
  # upstream nix-darwin brew-bundle command/flags/env and restores the previous
  # developer dir even when bundle fails.
  system.activationScripts.homebrew.text = lib.mkForce (brewBundleWithoutSelectedXcode ''
    # Homebrew Bundle
    echo >&2 "Homebrew bundle..."
    if [ -f "${config.homebrew.prefix}/bin/brew" ]; then
      ${config.homebrew.onActivation.brewBundleCmd { onlyCheck = false; }}
    else
      echo -e "\e[1;31merror: Homebrew is not installed, skipping...\e[0m" >&2
    fi
  '');
}
