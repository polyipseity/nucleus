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
    name: svc:
    svc ? platforms.macos && svc.platforms.macos ? type && svc.platforms.macos.type != "omitted"
  ) servicesJSON;

  systemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (name: svc: svc.logging.dirs.system or [ ]) macosServices)
  );

  userLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (name: svc: svc.logging.dirs.user or [ ]) macosServices)
  );

  chownLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        name: svc: if svc.platforms.macos.runAsUser or false then svc.logging.dirs.system or [ ] else [ ]
      ) macosServices
    )
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

    # ---- ensureSystemLogDirs ----------------------------------------------------
    # Create system log directories for all nucleus launchd daemons before they
    # start, so launchd can open StandardOutPath / StandardErrorPath files.
    # Runs in extraActivation (before nix-darwin's launchd step) so the dirs
    # exist before launchd tries to start daemons.
    system_log_dir="${config.nucleus.logging.systemLogDir}"
    for subdir in ${builtins.toString systemLogDirs}; do
      if ! /bin/mkdir -p "$system_log_dir/$subdir"; then
        echo "logging: failed to create $system_log_dir/$subdir." >&2
      fi
    done
    # Create user-level log dir for camilladsp/camillagui-backend so launchd can
    # open stdout/stderr, then chown to the console user so the daemon process
    # (which runs as that user via UserName) can write to the log files.
    # undoc-supp: /dev/console may not exist (headless/SSH session); empty result is handled by the [ -n "$_console_user" ] guard.
    _console_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_console_user" ] && [ "$_console_user" != "/Users/root" ]; then
      _username="''${_console_user#/Users/}"
      for _sub in ${builtins.toString userLogDirs}; do
        /bin/mkdir -p "$_console_user/Library/Logs/nucleus/$_sub"
      done
      /usr/sbin/chown -R "$_username:staff" "$_console_user/Library/Logs/nucleus"

      # Chown system log subdirs used by UserName=polyipseity services so launchd
      # can create StandardOutPath/StandardErrorPath files as that user.
      # Services running as root (https-proxy, linux-builder, litellm,
      # service-watchdog) can write to any dir, so chowning these is safe.
      for _sub in ${builtins.toString chownLogDirs}; do
        # undoc-supp: system log subdir may not exist on first apply; best-effort ownership fix for each deployed service.
        /usr/sbin/chown "$_username:staff" "$system_log_dir/$_sub" 2>/dev/null || true
      done
    fi
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
  #   configureMissionControlSpansDisplays — spans-displays per-user pref
  #   configureMonitorColorProfile     — clear ColorSync device cache
  #   clearFinderCache                 — purge stale Finder state for desktop visibility
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
    /usr/bin/xcode-select --switch "${pkgs.apple-sdk}"

    # ---- configureBatteryPolicy ------------------------------------------------
    ${builtins.readFile ../../scripts/macos-battery-policy.sh}

    # ---- configureChargeLimit --------------------------------------------------
    ${builtins.readFile ../../scripts/macos-charge-limit.sh}

    # ---- configureSshAccess -----------------------------------------------------
    ${builtins.readFile ../../scripts/macos-ssh-access.sh}

    # ---- configureMiddleClick -------------------------------------------------
    ${builtins.readFile ../../scripts/macos-middle-click.sh}
    # ---- configureMountyLoginItem ---------------------------------------------
    ${builtins.readFile ../../scripts/macos-mounty-login-item.sh}
    # ---- configureLinearMousePreferences --------------------------------------
    ${builtins.readFile ../../scripts/macos-linearmouse-prefs.sh}
    # ---- configureGimpScrollSensitivity ---------------------------------------
    ${builtins.readFile ../../scripts/macos-gimp-scroll-sensitivity.sh}

    # ---- configureMissionControlSpansDisplays ----------------------------------
    ${builtins.readFile ../../scripts/macos-mission-control.sh}

    # ---- configureMonitorColorProfile ------------------------------------------
    ${builtins.readFile ../../scripts/macos-color-profile.sh}

    # ---- clearFinderCache -------------------------------------------------------
    ${builtins.readFile ../../scripts/macos-clear-finder-cache.sh}

    # ---- disableSpotlight -------------------------------------------------------
    ${builtins.readFile ../../scripts/macos-disable-spotlight.sh}

    # ---- nvimLauncher -----------------------------------------------------------
    ${builtins.readFile ../../scripts/macos-nvim-launcher.sh}

    # ---- ensureSystemLogDirs (duplicated from extraActivation) -----------------
    # Also ensure directories exist during postActivation in case the log dir
    # config changed (systemLogDir is evaluated at activation time).
    system_log_dir="${config.nucleus.logging.systemLogDir}"
    for subdir in ${builtins.toString systemLogDirs}; do
      if ! /bin/mkdir -p "$system_log_dir/$subdir"; then
        echo "logging: failed to create $system_log_dir/$subdir." >&2
      fi
    done
    # undoc-supp: /dev/console may not exist; guards below handle empty/root.
    _camilladsp_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_camilladsp_user" ] && [ "$_camilladsp_user" != "/Users/root" ]; then
      /bin/mkdir -p "$_camilladsp_user/Library/Logs/nucleus/camilladsp"
    fi

    # ---- verify-homebrew-unpinnable ----------------------------------------------
    ${builtins.readFile ../../scripts/macos-verify-homebrew.sh}

    # ---- disableSteamAutoStartup ------------------------------------------------
    ${builtins.readFile ../../scripts/macos-disable-steam-autostart.sh}

    # ---- jellyfin-sync -----------------------------------------------------------
    # Converge Jellyfin accounts and libraries declared in src/modules/users.json
    # with a running Jellyfin server.
    #
    # WHY a separate script instead of inline shell: the sync logic performs
    # runtime imperative operations (SOPS decryption, API polling, token auth,
    # diff-and-converge) that Nix's declarative model cannot express.  Keeping
    # it in src/scripts/jellyfin-sync.sh avoids duplicating 600+ lines of shell
    # across hosts and keeps the activation file scoped to macOS-specific hooks.
    #
    # NUCLEUS_REPO_ROOT is set by apply.sh and forwarded through sudo.  If unset,
    # skip gracefully.
    jellyfin_repo_root="$NUCLEUS_REPO_ROOT"
    if [ -n "$jellyfin_repo_root" ] && [ -f "$jellyfin_repo_root/src/scripts/jellyfin-sync.sh" ]; then
      NUCLEUS_REPO_ROOT="$jellyfin_repo_root" sh "$jellyfin_repo_root/src/scripts/jellyfin-sync.sh"
    fi

    # ---- verifyNucleusServices ---------------------------------------------------
    # Warn-only verification that all managed services are running.
    # Failing to start a service should not block activation, but the warning
    # surfaces issues that operators can investigate post-apply.
    # nucleus-svc is expected to be in PATH after bootstrap.
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: some services are inactive (non-fatal; check /var/log/nucleus/ for details)" >&2
      fi
    fi
  '';
}
