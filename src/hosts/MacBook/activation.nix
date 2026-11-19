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

  # Stable SYSTEM-root toolchain links (DEVELOPER_DIR/SDKROOT point here). WHY computed
  # here too: extraActivation converges before homebrew so a brew-bundle abort cannot
  # leave xcode-select and the apple-sdk link diverged; postActivation still converges.
  toolchainLinks = import ../../modules/lib/toolchain-links.nix { inherit lib pkgs; };
  toolchainTargetsJson = builtins.toJSON (
    builtins.mapAttrs (_name: target: "${target}") (toolchainLinks.linkTargetsFor "MacBook")
  );

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
    # ---- ensure-local-install-dirs -----------------------------------------------
    # WHY: the source-built ntfs-3g consumes its fuse-t provider under /usr/local
    # (lib/libfuse-t.dylib, include/fuse), so both parent directories are created
    # here instead of relying on whatever installed the provider.
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

    # ---- configure-xcode-select (pre-homebrew) -----------------------------------
    # WHY run before nix-darwin homebrew: brew bundle validates the selected developer
    # dir (Xcode >= 27.0 on macOS 27), so the versioned apple-sdk-enhanced shim must be
    # selected before homebrew activation runs.
    /usr/bin/xcode-select --switch "${appleSdkEnhanced}"

    # ---- converge-toolchain-links (pre-homebrew) ---------------------------------
    # WHY run before nix-darwin homebrew: brew bundle aborts activation on failure, so a
    # postActivation-only pass can leave the stable apple-sdk link (DEVELOPER_DIR/SDKROOT)
    # behind the newly selected xcode-select dev dir. Converging here keeps them consistent
    # for bundle-time consumers and on rerun recovery without masking brew/homebrew
    # failures; converge-toolchain-links is idempotent and exits non-zero on real
    # conflicts, and postActivation convergence remains the end-state pass.
    "${activationBundle}/src/scripts/configs/converge-toolchain-links.sh" \
      "${pkgs.jq}/bin/jq" \
      "${toString (toolchainLinks.linkDirFor "MacBook")}" \
      '${toolchainTargetsJson}'

    # ---- provision-homebrew-gcc16 (pre-homebrew) ---------------------------------
    # WHY Homebrew 7 compiler selection (clang, then gcc 8..16) rejects clang here because
    # DevelopmentTools.clang_build_version is null (/usr/bin/clang aborts SIGABRT under the
    # Nix-selected developer dir and Nix clang output is not an Apple build version), and
    # locate() cannot resolve gcc-N via /usr/bin or xcrun (xcrun also aborts) when no CLT,
    # real Xcode, or brewed gcc is installed. Providing $HOMEBREW_PREFIX/bin/gcc-16 as a
    # symlink to the Nix gcc wrapper in the enhanced SDK makes locate("gcc-16") and
    # gcc_version succeed, so formula build-env/compiler selection works for
    # openai/tools/softnet without installing CLT, making a real Xcode the default dev
    # dir, or running `brew install gcc`. Runs in extraActivation so it is in place before
    # nix-darwin's homebrew activation/brew bundle phase.
    _hb_gcc16="/opt/homebrew/bin/gcc-16"
    _hb_gcc16_target="${appleSdkEnhanced}/usr/bin/gcc"
    /bin/mkdir -p /opt/homebrew/bin
    if [ -e "$_hb_gcc16" ] && [ ! -L "$_hb_gcc16" ]; then
      echo "activation: refusing to replace non-symlink $_hb_gcc16; expected Homebrew-locatable gcc-16 symlink to $_hb_gcc16_target" >&2
      exit 1
    fi
    /bin/ln -sfn "$_hb_gcc16_target" "$_hb_gcc16"
  '';

  # WHY lib.mkBefore: it puts these fragments ahead of the home-manager call
  # that nix-darwin appends to postActivation.text at priority 1000.
  # WHY lib.mkMerge: mkBefore runs ahead of Home Manager (appended at priority 1000);
  # mkAfter runs after it so the Preboot refresh sees decrypted wallpapers.
  system.activationScripts.postActivation.text = lib.mkMerge [
    (lib.mkBefore ''
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
    '')

    # WHY lib.mkAfter: home-manager activation (including provision-wallpapers in
    # wallpapers.nix) runs in the HM phase appended at priority 1000; this refresh
    # must run after decrypted wallpapers exist in ~/Pictures/wallpapers. The
    # kickstart of com.apple.wallpaper.agent is blocked by SIP (exit 150), so the
    # unsupported fallback writes the Preboot Wallpapers store directly.
    (lib.mkAfter ''
      # ---- refresh-preboot-wallpaper -----------------------------------------------
      "${activationBundle}/src/hosts/MacBook/scripts/macos-refresh-preboot-wallpaper.sh"
    '')
  ];
}
