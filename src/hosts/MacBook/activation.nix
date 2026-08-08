# MacBook/activation.nix — nix-darwin system activation hooks for the MacBook.
#
# All scripts run as root during `darwin-rebuild switch`.  Because
# system.activationScripts is a nix-darwin-only option they are guaranteed to
# execute on macOS; no OS check inside the shell body is needed.
#
# WHY: postActivation.text, not custom script names:
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
    _: svc: svc ? hosts.MacBook && svc.hosts.MacBook ? type && svc.hosts.MacBook.type != "omitted"
  ) servicesJSON;

  systemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.system or [ ]) macosServices)
  );

  userLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.user or [ ]) macosServices)
  );

  usersDir = ../../users;
  usersOverlay = builtins.readDir usersDir;
  replicaSyncUserLogDirs = lib.unique (
    lib.flatten (
      map
        (
          userName:
          let
            cloudDrivesPath = "${usersDir}/${userName}/cloud-drives.json";
            cloudDrivesCfg =
              if builtins.pathExists cloudDrivesPath then
                builtins.fromJSON (builtins.readFile cloudDrivesPath)
              else
                { replicas = [ ]; };
            scheduledReplicas = builtins.filter (replica: (replica.fallbackTimer.enable or true)) (
              cloudDrivesCfg.replicas or [ ]
            );
          in
          map (replica: "replica-sync-${replica.id}") scheduledReplicas
        )
        (
          lib.filter (name: usersOverlay.${name} == "directory" && name != "default") (
            builtins.attrNames usersOverlay
          )
        )
    )
  );

  userLogDirsWithReplicas = lib.unique (userLogDirs ++ replicaSyncUserLogDirs);

  chownLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc: if svc.hosts.MacBook.runAsUser or false then svc.logging.dirs.system or [ ] else [ ]
      ) macosServices
    )
  );

  # Baked at eval time from NUCLEUS_REPO_ROOT (set by apply.sh). Used to
  # resolve the repo checkout root in activation blocks that embed or invoke
  # repo-local scripts.
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  macBookUserLogDirSuffix = lib.removePrefix "~/" servicesJSON."$logging".MacBook.logDir;

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
    # ---- ensure-fuse-t-headers-dir --------------------------------------------------
    # fuse-t cask post-install symlinks headers into /usr/local/include.  If that
    # directory doesn't exist, the cask install silently skips the link step,
    # leaving ntfs-3g build with no fuse headers.  Create it pre-emptively.
    /bin/mkdir -p /usr/local/include

    # ---- ensure-log-dirs -----------------------------------------------------------
    # Create system log dirs (all hosts) and macOS-specific user log dirs (console
    # user + chown). Shared with NixOS via ensure-log-dirs.sh.
    "${activationBundle}/src/scripts/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString systemLogDirs}" \
      "${builtins.toString userLogDirsWithReplicas}" \
      "${builtins.toString chownLogDirs}" \
      "${macBookUserLogDirSuffix}"
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
  #   configureUtmRendererPrefs        — UTM Apple Core OpenGL (CGL) renderer for Android guest
  #   disableSpotlight                 — disable all Spotlight hotkeys + service
  #   removeCommandLineTools           — delete Apple CLT install tree (not receipts)
  #   configureXcodeSelect             — xcode-select --switch to apple-sdk-enhanced
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- remove-command-line-tools -----------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-remove-command-line-tools.sh" \
      "${config.nucleus.logging.systemLogDir}/command-line-tools.log"

    # ---- configure-xcode-select --------------------------------------------------
    # Point the system developer directory at the Nix apple-sdk store path so
    # xcrun (invoked by rustc/cargo for SDK discovery) works without Xcode CLT
    # installed.  remove-command-line-tools above deletes the CLT tree when
    # present; this switch is the system-level hook for non-shell process trees.
    # Without both steps, native-code builds outside a Nix devShell can trigger
    # the CLT installation dialog.
    # WHY: xcode-select --switch (not just DEVELOPER_DIR):
    #   DEVELOPER_DIR only helps processes that inherit the shell environment.
    #   launchd services, VS Code tasks with non-shell exec, and other non-shell
    #   process trees rely on the system-level developer directory set via
    #   /usr/bin/xcode-select.  The activation script runs as root during
    #   darwin-rebuild switch, so no sudo wrapper is needed.
    /usr/bin/xcode-select --switch "${appleSdkEnhanced}"

    # ---- configure-symlink-farm ------------------------------------------------
    # Create/update symlinks in /usr/local/bin for tools that GUI apps resolve
    # via PATH directly (without xcrun).  Only operates on Nix store symlinks
    # and leaves regular files and non-Nix symlinks untouched.
    "${activationBundle}/src/hosts/MacBook/scripts/macos-symlink-farm.sh" \
      "${symlinkFarmEntries}" \
      "${config.nucleus.logging.systemLogDir}/symlink-farm.log"

    # ---- configure-battery-policy ------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-battery-policy.sh"

    # ---- configure-charge-limit --------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-charge-limit.sh"

    # ---- configure-ssh-access -----------------------------------------------------
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

    # ---- configure-middle-click -------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-enable-middle-click.sh"

    # ---- configure-mounty-login-item ---------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-register-mounty-login-item.sh"
    # ---- configure-linearmouse-preferences --------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-set-linearmouse-prefs.sh"
    # ---- configure-utm-renderer-prefs -------------------------------------------
    # Pin UTM's global renderer backend to Apple Core OpenGL (CGL) in the
    # sandboxed app container so the Android (LineageOS) guest UI appears
    # after boot (ANGLE (Metal) hides it; CGL is the UTM 5.x maintained GL
    # backend, QEMURendererBackend = 3).  This does not prevent the recurring
    # "display freezes randomly" bug -- that is a renderer-orthogonal
    # client-side SPICE stall (UTM #2221, CocoaSpice#5); UTM 5.0.4 SPICE
    # renderer fixes and keeping the VM window visible are the mitigations.
    # See .agents/instructions/utm-android-freeze.instructions.md.
    # Runs unconditionally: the pref is a global UTM setting, harmless when no
    # Android VM is enabled, and idempotent when already set.
    "${activationBundle}/src/hosts/MacBook/scripts/macos-set-utm-renderer.sh"
    # ---- configure-gimp-scroll-sensitivity ---------------------------------------
    "${activationBundle}/src/scripts/configs/configure-gimp-scroll-sensitivity.sh"

    # ---- configure-mission-control-spans-displays ----------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-mission-control.sh"

    # ---- configure-monitor-color-profile ------------------------------------------
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

    # ---- clear-finder-cache -------------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-clear-finder-cache.sh"

    # ---- disable-spotlight -------------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-disable-spotlight.sh"

    # ---- launcher -----------------------------------------------------------
    # Pass empty arg to trigger runtime resolution from /dev/console (macOS).
    "${activationBundle}/src/scripts/editors/launch-nvim.sh" ""

    # ---- ensureLogDirs (repeated from extraActivation) --------------------------
    # Also ensure log directories exist during postActivation (belt-and-suspenders
    # in case systemLogDir was reconfigured at activation time).
    "${activationBundle}/src/scripts/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString systemLogDirs}" \
      "${builtins.toString userLogDirsWithReplicas}" \
      "${builtins.toString chownLogDirs}" \
      "${macBookUserLogDirSuffix}"
    # check-suppress:suppression_doc: /dev/console may not exist; guards below handle empty/root.
    _camilladsp_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_camilladsp_user" ] && [ "$_camilladsp_user" != "/Users/root" ]; then
      /bin/mkdir -p "$_camilladsp_user/nucleus/logs/camilladsp"
    fi

    # ---- homebrew-pin-verify ----------------------------------------------
    # Warning-only check that installed Homebrew versions match lockfile.
    # Never fails activation.
    "${activationBundle}/src/hosts/MacBook/scripts/macos-verify-homebrew-pin.sh" "${repoRoot}"

    # ---- disableSteamAutoStartup ------------------------------------------------
    "${activationBundle}/src/scripts/configs/disable-steam-autostart.sh"

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
