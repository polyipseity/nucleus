# MacBook/activation.nix — nix-darwin system activation hooks for the MacBook.
#
# All scripts run as root during `darwin-rebuild switch`.  Because
# system.activationScripts is a nix-darwin-only option they are guaranteed to
# execute on macOS; no OS check inside the shell body is needed.
#
# WHY postActivation.text, not custom script names:
#   nix-darwin's activation-scripts.nix (rev 8c62fba) assembles only a fixed
#   hardcoded list of named scripts into the activate binary.  Any name outside
#   that list (e.g. configureBatteryPolicy, enableScreenSharing) is silently
#   ignored.  The user extension points are extraActivation (before openssh)
#   and postActivation (after homebrew, last before the gc-root symlink).
#   lib.mkBefore ensures these fragments are prepended before home-manager's
#   HM activation call, which is also appended to postActivation.text.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);

  macosServices = lib.filterAttrs (
    _: svc: svc ? platforms.macos && svc.platforms.macos ? type && svc.platforms.macos.type != "omitted"
  ) servicesJSON;

  systemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.system or [ ]) macosServices)
  );

  userLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.user or [ ]) macosServices)
  );

  chownLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc: if svc.platforms.macos.runAsUser or false then svc.logging.dirs.system or [ ] else [ ]
      ) macosServices
    )
  );

  # Baked at eval time from NUCLEUS_REPO_ROOT (set by apply.sh). Used to
  # resolve the repo checkout root in activation blocks that embed or invoke
  # repo-local scripts.
  activationBundle = pkgs.callPackage ../../modules/lib/activation-bundle.nix { };

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Enhanced apple-sdk with real tool symlinks in usr/bin/ so xcrun shims
  # resolve to nixpkgs tools.  Used by configureXcodeSelect below.
  appleSdkEnhanced = import ../../modules/lib/apple-sdk-enhanced.nix { inherit pkgs lib; };

  # Symlink farm tool entries for /usr/local/bin/.  GUI apps that spawn()
  # tools by name (python3, git, make) resolve via PATH without xcrun.
  appleSdkTools = import ../../modules/lib/apple-sdk-tools.nix { inherit pkgs; };
  symlinkFarmEntries = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: target: "${target}->${name}") appleSdkTools.symlinkFarmTools
  );
in
{
  # ---------------------------------------------------------------------------
  # Declarative power-management settings handled by nix-darwin's power module.
  # These translate to systemsetup / pmset calls at activation time.
  #   computer = "never" — idle sleep disabled            (was: pmset -a sleep 0)
  #   display  = 1       — display sleeps after 1 minute to save power
  #   harddisk = "never" — disk sleep disabled            (was: pmset -a disksleep 0)
  #   restartAfterPowerFailure is intentionally omitted because this machine
  #   model/firmware does not support it; setting it at all causes activation
  #   failure on this hardware.
  # ---------------------------------------------------------------------------
  power.sleep.computer = "never";
  power.sleep.display = 1;
  power.sleep.harddisk = "never";
  # power.restartAfterPowerFailure = true;  # Keep the comment and keep it disabled.

  # ---------------------------------------------------------------------------
  # extraActivation — runs before openssh / Homebrew bundle.
  # ---------------------------------------------------------------------------
  system.activationScripts.extraActivation.text = ''
    # ---- ensureFuseTHeadersDir --------------------------------------------------
    # fuse-t cask post-install symlinks headers into /usr/local/include.  If that
    # directory doesn't exist, the cask install silently skips the link step,
    # leaving ntfs-3g build with no fuse headers.  Create it pre-emptively.
    /bin/mkdir -p /usr/local/include

    # ---- ensureLogDirs -----------------------------------------------------------
    # Create system log dirs (all hosts) and macOS-specific user log dirs (console
    # user + chown). Shared with NixOS via ensure-log-dirs.sh.
    "${activationBundle}/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString systemLogDirs}" \
      "${builtins.toString userLogDirs}" \
      "${builtins.toString chownLogDirs}"
  '';

  # ---------------------------------------------------------------------------
  # postActivation fragments (all macbook-specific activation scripts)
  #
  # lib.mkBefore (priority 500) positions these fragments before the
  # home-manager activation call that nix-darwin appends to postActivation.text
  # at default priority 1000.  Each logical section is separated by a shell
  # comment banner for readability in the assembled activate script.
  #
  # Scripts included:
  #   configureBatteryPolicy           — pmset AC/battery policy
  #   configureChargeLimit             — 80 % charge cap via battery CLI / bclm
  #   configureSshAccess               — allow all users SSH access by removing com.apple.access_ssh group
  #   configureGimpScrollSensitivity   — GIMP drag-zoom-speed (25% of default)
  #   configureLinearMousePreferences  — LinearMouse update-check suppression
  #   configureMiddleClick             — 4-finger gesture + native login item
  #   configureMountyLoginItem         — native login item registration
  #   configureMissionControlSpansDisplays — spans-displays per-user pref
  #   configureMonitorColorProfile     — clear ColorSync device cache
  #   clearFinderCache                 — purge stale Finder state for desktop visibility
  #   configureNvimLauncher            — macOS-specific neovim launcher
  #   disableSpotlight                 — disable all Spotlight hotkeys + service
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- configureXcodeSelect --------------------------------------------------
    # Point the system developer directory at the Nix apple-sdk store path so
    # xcrun (invoked by rustc/cargo for SDK discovery) works without Xcode CLT
    # installed.  Without this, every native-code build outside a Nix devShell
    # triggers the CLT installation dialog.
    # WHY xcode-select --switch (not just DEVELOPER_DIR):
    #   DEVELOPER_DIR only helps processes that inherit the shell environment.
    #   launchd services, VS Code tasks with non-shell exec, and other non-shell
    #   process trees rely on the system-level developer directory set via
    #   /usr/bin/xcode-select.  The activation script runs as root during
    #   darwin-rebuild switch, so no sudo wrapper is needed.
    /usr/bin/xcode-select --switch "${appleSdkEnhanced}"

    # ---- configureSymlinkFarm ------------------------------------------------
    # Create/update symlinks in /usr/local/bin for tools that GUI apps resolve
    # via PATH directly (without xcrun).  Only operates on Nix store symlinks
    # and leaves regular files and non-Nix symlinks untouched.
    "${activationBundle}/hosts/MacBook/macos-symlink-farm.sh" \
      "${symlinkFarmEntries}" \
      "${config.nucleus.logging.systemLogDir}/symlink-farm.log"

    # ---- configureBatteryPolicy ------------------------------------------------
    ${builtins.readFile ../../scripts/hosts/MacBook/macos-configure-battery-policy.sh}

    # ---- configureChargeLimit --------------------------------------------------
    "${activationBundle}/hosts/MacBook/macos-charge-limit.sh"

    # ---- configureSshAccess -----------------------------------------------------
    # Allow all users to connect via SSH by removing the macOS access-control
    # group. When com.apple.access_ssh does not exist, sshd allows any user
    # (subject to sshd_config AllowUsers/AllowGroups).
    # See: System Settings → General → Sharing → Remote Login → (i) → "Allow
    # access for: All Users"
    if /usr/sbin/dseditgroup -o delete -q com.apple.access_ssh 2>/dev/null; then
      echo "ssh: removed com.apple.access_ssh group; all users can now connect via SSH."
    else
      echo "ssh: com.apple.access_ssh group does not exist (already allowing all users)." >&2
    fi

    # ---- configureMiddleClick -------------------------------------------------
    "${activationBundle}/hosts/MacBook/macos-enable-middle-click.sh"

    # ---- configureMountyLoginItem ---------------------------------------------
    "${activationBundle}/hosts/MacBook/macos-register-mounty-login-item.sh"
    # ---- configureLinearMousePreferences --------------------------------------
    "${activationBundle}/hosts/MacBook/macos-set-linearmouse-prefs.sh"
    # ---- configureGimpScrollSensitivity ---------------------------------------
    "${activationBundle}/configs/configure-gimp-scroll-sensitivity.sh"

    # ---- configureMissionControlSpansDisplays ----------------------------------
    "${activationBundle}/hosts/MacBook/macos-configure-mission-control.sh"

    # ---- configureMonitorColorProfile ------------------------------------------
    # Clears the ColorSync device-profile cache so that newly connected monitors
    # re-trigger profile detection and pick up the correct ICC profile.
    # ColorSync is a macOS-only subsystem; NixOS uses colord for ICC profile
    # management (handled by GNOME) and Windows has its own Color Management
    # subsystem — neither requires an equivalent cache-clearing step here.
    # Guard with a file-existence check: on fresh installs or machines with no
    # custom color profile the plist never exists, and `defaults delete` on a
    # missing domain emits a noisy "Domain not found" error that is neither a
    # real failure nor actionable.  Using [ -f ] avoids that entirely — if the
    # file is present we delete it; if not, there is nothing to do.
    if [ -f /Library/Preferences/com.apple.ColorSync.DeviceCache.plist ]; then
      /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache
    fi

    # ---- clearFinderCache -------------------------------------------------------
    "${activationBundle}/hosts/MacBook/macos-clear-finder-cache.sh"

    # ---- disableSpotlight -------------------------------------------------------
    "${activationBundle}/hosts/MacBook/macos-disable-spotlight.sh"

    # ---- nvimLauncher -----------------------------------------------------------
    # Pass empty arg to trigger runtime resolution from /dev/console (macOS).
    "${activationBundle}/editors/launch-nvim.sh" ""

    # ---- ensureLogDirs (repeated from extraActivation) --------------------------
    # Also ensure log directories exist during postActivation (belt-and-suspenders
    # in case systemLogDir was reconfigured at activation time).
    "${activationBundle}/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString systemLogDirs}" \
      "${builtins.toString userLogDirs}" \
      "${builtins.toString chownLogDirs}"
    # undoc-supp: /dev/console may not exist; guards below handle empty/root.
    _camilladsp_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_camilladsp_user" ] && [ "$_camilladsp_user" != "/Users/root" ]; then
      /bin/mkdir -p "$_camilladsp_user/Library/Logs/nucleus/camilladsp"
    fi

    # ---- homebrew-pin-verify ----------------------------------------------
    # Warning-only check that installed Homebrew versions match lockfile.
    # Never fails activation.
    "${activationBundle}/hosts/MacBook/macos-verify-homebrew-pin.sh" "${repoRoot}" || true  # undoc-supp: warning-only version check; must not abort activation even if script errors.

    # ---- disableSteamAutoStartup ------------------------------------------------
    "${activationBundle}/configs/disable-steam-autostart.sh"

    # ---- jellyfin-sync -----------------------------------------------------------
    # Converge Jellyfin accounts and libraries declared in src/modules/users.json
    # with a running Jellyfin server.
    #
    # WHY subprocess invocation (not readFile + replaceStrings): the activation
    # bundle already contains the full scripts/ tree.  NUCLEUS_REPO_ROOT and PATH
    # are set in the environment so the script resolves the repo root at runtime
    # via derive_repo_root (or falls back to derive_repo_root / NUCLEUS_REPO_ROOT).
    # SOPS_AGE_KEY_FILE defaults to /etc/sops/age/machine.txt.
    ${
      lib.optionalString (repoRoot != "") "export NUCLEUS_REPO_ROOT=${lib.escapeShellArg repoRoot}
    "
    }export PATH="${pkgs.jq}/bin:${pkgs.sops}/bin:$PATH"
    "${activationBundle}/services/jellyfin-sync.sh"

    # ---- verifyNucleusServices ---------------------------------------------------
    # Warn-only verification that all managed services are running.
    # Failing to start a service should not block activation, but the warning
    # surfaces issues that operators can investigate post-apply.
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
