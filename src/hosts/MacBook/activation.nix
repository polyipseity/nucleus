# MacBook/activation.nix - nix-darwin system activation hooks for the MacBook.
#
# All scripts run as root during `darwin-rebuild switch`.
#
# WHY postActivation.text and not custom script names: nix-darwin's
# activation-scripts.nix (rev 8c62fba) assembles only a fixed hardcoded list of
# named scripts into the activate binary, and any other name is silently
# ignored. The user extension points are extraActivation and postActivation.
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

  # WHY `svc.logging` is unguarded: a service that omits the block must fail eval
  # loudly, not be silently skipped and crash launchd with EX_CONFIG 78.
  # `dirs` is optional, so only that level is guarded.
  systemLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc:
        let
          log = svc.logging;
        in
        (log.dirs or { }).system or [ ]
      ) macosServices
    )
  );

  userLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc:
        let
          log = svc.logging;
        in
        (log.dirs or { }).user or [ ]
      ) macosServices
    )
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

  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  macBookUserLogDirSuffix = lib.removePrefix "~/" servicesJSON."$logging".MacBook.logDir;

  # Enhanced apple-sdk, so xcrun shims resolve to nixpkgs tools.
  appleSdkEnhanced = import ../../modules/lib/apple-sdk-enhanced.nix { inherit pkgs lib; };

  # GUI apps that spawn() tools by name resolve via PATH without xcrun.
  appleSdkTools = import ../../modules/lib/apple-sdk-tools.nix { inherit pkgs; };
  symlinkFarmEntries = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: target: "${target}->${name}") appleSdkTools.symlinkFarmTools
  );

  nucleusRoots = import ../../modules/lib/nucleus-roots.nix { inherit lib pkgs; };
in
{
  power.sleep.computer = "never";
  power.sleep.display = 1;
  power.sleep.harddisk = "never";
  # WHY no restartAfterPowerFailure: this model and firmware do not support it,
  # and setting it at all fails activation.
  # power.restartAfterPowerFailure = true;  # Keep the comment and keep it disabled.

  system.activationScripts.extraActivation.text = ''
    # ---- ensure-macfuse-install-dirs -----------------------------------------------
    # WHY: the macFUSE cask postflight sets ownership on both directories, so
    # they must exist before the cask installs.
    /bin/mkdir -p /usr/local/include /usr/local/lib

    # ---- ensure-nucleus-roots ------------------------------------------------------
    # The console user is unknown at eval time, so resolve it at activation time.
    # check-suppress:suppression_doc: /dev/console may not exist; guards handle empty/root.
    _console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_console_user" ] && [ "$_console_user" != "root" ]; then
      # check-suppress:suppression_doc: dscl may fail if the user record is missing; treat as absent.
      _console_home="$(/usr/bin/dscl . -read "/Users/''${_console_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
      if [ -n "$_console_home" ]; then
        ${nucleusRoots.mkNucleusRootSymlinks {
          userHome = "$_console_home";
          userName = "$_console_user";
        }}
        ${nucleusRoots.mkNucleusHub {
          userHome = "$_console_home";
          userName = "$_console_user";
        }}
      fi
    fi

    # WHY imperative: Home Manager orders activation alphabetically, not by
    # dependency, so this must run after the root symlinks resolve.
    "${activationBundle}/src/scripts/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString systemLogDirs}" \
      "${builtins.toString userLogDirsWithReplicas}" \
      "${builtins.toString chownLogDirs}" \
      "${macBookUserLogDirSuffix}"
  '';

  # WHY lib.mkBefore: it puts these fragments ahead of the home-manager call
  # that nix-darwin appends to postActivation.text at priority 1000.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- remove-command-line-tools -----------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-remove-command-line-tools.sh" \
      "${config.nucleus.logging.systemLogDir}/command-line-tools.log"

    # ---- configure-xcode-select --------------------------------------------------
    # WHY xcode-select and not only DEVELOPER_DIR: DEVELOPER_DIR reaches only
    # processes that inherit the shell environment, and rustc and cargo need SDK
    # discovery in launchd services and other non-shell process trees too.
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
    # WHY the `battery` CLI: it is the only convergent gate for the 80 % cap. The
    # native macOS Charge Limit has no pmset key, no profile payload, and no CLI,
    # so it stays a manual setting (see MANUAL.md).
    "${activationBundle}/src/hosts/MacBook/scripts/macos-charge-limit.sh"

    # ---- macos-configure-menu-bar-icons --------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh"

    # ---- macos-configure-menu-bar -------------------------------------------------
    # System items have no apps.json entry, so they stay here.
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-menu-bar.sh"

    # ---- configure-ssh-access -----------------------------------------------------
    # Deleting com.apple.access_ssh is what allows all users. When the group is
    # already absent, sshd allows any user subject to AllowUsers/AllowGroups.
    # See System Settings > General > Sharing > Remote Login > (i) > Allow access for.
    if /usr/sbin/dseditgroup -o delete -q com.apple.access_ssh 2>/dev/null; then
      echo "ssh: removed com.apple.access_ssh group; all users can now connect via SSH."
    else
      echo "ssh: com.apple.access_ssh group does not exist (already allowing all users)." >&2
    fi

    # ---- configure-app-autostart ------------------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-app-autostart.sh"
    # ---- configure-linearmouse-preferences --------------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-set-linearmouse-prefs.sh"
    # ---- configure-utm-prefs ----------------------------------------------------
    # WHY the app container: the sandboxed prefs survive UTM updates. Runs
    # unconditionally, it is idempotent and harmless when UTM is absent.
    "${activationBundle}/src/hosts/MacBook/scripts/macos-set-utm-prefs.sh"
    # ---- configure-gimp-scroll-sensitivity ---------------------------------------
    "${activationBundle}/src/scripts/configs/configure-gimp-scroll-sensitivity.sh"

    # ---- configure-mission-control-spans-displays ----------------------------------
    "${activationBundle}/src/hosts/MacBook/scripts/macos-configure-mission-control.sh"

    # ---- configure-monitor-color-profile ------------------------------------------
    # WHY the guard: `defaults delete` on a missing domain prints a noisy
    # "Domain not found" that is neither a real failure nor actionable.
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

    # ---- ensure-camilladsp-log-dir ----------------------------------------------
    # check-suppress:suppression_doc: /dev/console may not exist; guards below handle empty/root.
    _camilladsp_user="/Users/$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    if [ -n "$_camilladsp_user" ] && [ "$_camilladsp_user" != "/Users/root" ]; then
      /bin/mkdir -p "$_camilladsp_user/Library/Application Support/nucleus/logs/camilladsp"
    fi

    # ---- verifyNucleusServices ---------------------------------------------------
    # Warn-only: a service that failed to start must not block activation.
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
