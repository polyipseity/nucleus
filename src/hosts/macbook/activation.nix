# macbook/activation.nix — nix-darwin system activation hooks for the MacBook.
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
{ lib, ... }:
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
  #   configureGimpScrollSensitivity   — GIMP drag-zoom-speed (25% of default)
  #   configureLinearMousePreferences  — LinearMouse update-check suppression
  #   configureMissionControlSpansDisplays — spans-displays per-user pref
  #   configureMonitorColorProfile     — clear ColorSync device cache
  #   clearFinderCache                 — purge stale Finder state for desktop visibility
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- configureBatteryPolicy ------------------------------------------------
    # Enforce pmset values directly for AC and battery because newer macOS
    # releases can ignore or partially override higher-level power options.
    #
    # Invariant:
    #   Global (-a): standby=1, ttyskeepawake=1, hibernatemode=3, networkoversleep=0,
    #     tcpkeepalive=1, powernap=1, lidwake=1, hibernatefile=/var/vm/sleepimage
    #   AC (-c): displaysleep=1, sleep=0, disksleep=0, womp=1, lowpowermode=0
    #   Battery (-b): displaysleep=1, sleep=0, disksleep=0, womp=1, lowpowermode=1,
    #     lessbright=1 (when supported)
    #
    # NOTE — keys NOT settable via pmset CLI on this hardware (Apple Silicon /
    # macOS 15+): "Sleep On Power Button" and "SleepServices".  Both appear in
    # `pmset -g` output but are absent from `pmset -g cap` and rejected with a
    # usage error when written.  They are managed read-only by the OS/firmware.
    # The desired sleep-on-button behaviour must be set manually in System
    # Settings → General; SleepServices follows the powernap=1 setting above.
    #
    # womp=1 on both AC and battery: empirical pmset -g custom output confirms
    # the machine honours womp on battery; setting it on both sources ensures
    # inbound magic-packet wakes succeed regardless of power source.
    #
    # sleep=0 on battery: remote-desktop sessions (Chrome Remote Desktop, VNC/ARD,
    # SSH) must survive when the machine is on battery.  Idle sleep would
    # disconnect active sessions and prevent new inbound connections.
    #
    # displaysleep and disksleep are declared on both sources even with
    # lowpowermode=1 active on battery.  Empirical testing (pmset -g custom)
    # confirms all three battery values are honoured when applied after the
    # lowpowermode preset is set.
    #
    # The helper emits a clear error when any write fails so a mis-typed key
    # does not silently leave a stale policy in place.
    apply_pmset() {
      if ! /usr/bin/pmset "$@"; then
        echo "power: failed to apply pmset settings: $*" >&2
        return 1
      fi
    }

    pmset_supports() {
      capability="$1"
      # pmset -g cap rarely fails on a live macOS system; stderr is suppressed
      # to avoid confusing output when an unsupported capability probe returns
      # non-zero (grep handles the boolean result).  Any real pmset failure
      # surfaces separately when apply_pmset later tries to write the value.
      /usr/bin/pmset -g cap 2>/dev/null | /usr/bin/grep -Eq "(^|[[:space:]])$capability([[:space:]]|$)"
    }

    if [ -x /usr/bin/pmset ]; then
      # Global settings (-a) apply regardless of power source.
      #   standby=1: allow transition to deeper standby after extended sleep;
      #     keeps the machine in a recoverable low-power state for long idle
      #     periods without fully powering down.
      #   ttyskeepawake=1: prevent system sleep while any network terminal (SSH,
      #     ARD/VNC screen sharing) holds an active tty; critical for keeping
      #     live remote sessions from being dropped by an unexpected idle sleep.
      #   hibernatemode=3: safe-sleep — write RAM image to disk before sleeping
      #     so the session can be restored from disk if battery drains during
      #     sleep (mirrors Windows hybrid sleep).
      #   networkoversleep=0: suppress background network activity during sleep;
      #     deliberate remote wakes are handled by womp (AC) separately.
      #   tcpkeepalive=1: issue TCP keepalives through sleep so persistent SSH
      #     tunnels and remote-desktop sessions stay alive across sleep/wake
      #     cycles without requiring application-level keepalive configuration.
      #   powernap=1: allow background mail/calendar sync during Power Nap.
      #   lidwake=1: wake when the lid is opened (standard laptop ergonomics).
      apply_pmset -a standby 1 ttyskeepawake 1 hibernatemode 3 networkoversleep 0 tcpkeepalive 1 powernap 1 lidwake 1
      # hibernatefile set separately: a path argument on the same line as other
      # flag-value pairs is easy to misread as a flag rather than a path.
      apply_pmset -a hibernatefile /var/vm/sleepimage

      if pmset_supports lowpowermode; then
        # Set lowpowermode per source BEFORE applying per-source timers so that
        # any OS preset adjustments triggered by lowpowermode activation are
        # then overridden by the explicit values below.
        apply_pmset -c lowpowermode 0
        apply_pmset -b lowpowermode 1
      fi

      # AC settings: 1-minute display sleep, no idle system sleep, no disk sleep.
      # womp=1 (wake-on-Ethernet LAN): wake when a magic packet arrives over the
      # wired network; set on both AC and battery so remote wakes succeed
      # regardless of power source.
      apply_pmset -c displaysleep 1 sleep 0 disksleep 0 womp 1

      # Battery settings: 1-minute display sleep, no idle system sleep, no disk sleep.
      # womp=1: mirror the AC setting; machine honours womp on battery empirically.
      apply_pmset -b displaysleep 1 sleep 0 disksleep 0 womp 1

      if pmset_supports lessbright; then
        # lessbright dims the display on battery to extend runtime.
        # There is no separate AC-source control for brightness dimming.
        apply_pmset -b lessbright 1
      fi
    fi

    # ---- configureChargeLimit --------------------------------------------------
    # Keep charge capped at 80 % to reduce long-term battery wear on a mostly
    # docked development machine.
    #
    # On macOS 15+, bclm no longer works due kernel entitlement enforcement.
    # Prefer the maintained `battery` CLI (installed by the `battery` cask) and
    # run it as the active console user so user-scoped launch-agent state stays
    # in that user's home directory.
    #
    # bclm is retained as a fallback only for older macOS versions.
    console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    macos_major="$(/usr/bin/sw_vers -productVersion 2>/dev/null | /usr/bin/awk -F. '{print $1}')"

    battery_app="/Applications/battery.app"
    battery_cli=""
    for candidate in /usr/local/bin/battery /usr/local/co.palokaj.battery/battery; do
      if [ -x "$candidate" ]; then
        battery_cli="$candidate"
        break
      fi
    done

    if [ -n "$battery_cli" ] && [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      # -H sets HOME to the target user's home directory.  Without it, sudo
      # inherits HOME=/var/root from the root activation context, causing
      # battery to write its state files to /var/root/.battery/ which the
      # console user cannot write to.
      #
      # Redirect stdin/stdout/stderr to /dev/null: battery maintain forks a
      # long-running background daemon via `nohup ... &` that inherits open
      # file descriptors.  Without this redirect, the daemon holds the
      # activation pipeline's pipe write-end open indefinitely, causing any
      # `./scripts/bootstrap.sh apply ... | <cmd>` invocation to hang until
      # the daemon exits (which is never during normal operation).  The exit
      # code is still checked below so real failures are not silenced;
      # battery's own log file (~/.battery/battery.log) retains full
      # diagnostic output for post-failure inspection.
      if ! /usr/bin/sudo -H -u "$console_user" "$battery_cli" maintain 80 </dev/null >/dev/null 2>&1; then
        echo "power: battery maintain 80 failed for user '$console_user'." >&2
      fi
    elif [ -x /opt/homebrew/bin/bclm ]; then
      if [ -n "$macos_major" ] && [ "$macos_major" -ge 15 ]; then
        echo "power: bclm is unsupported on macOS >= 15; install and initialize the battery app to enforce 80% charge limit." >&2
      else
        if ! /opt/homebrew/bin/bclm write 80; then
          echo "power: bclm write 80 failed." >&2
        fi
        if ! /opt/homebrew/bin/bclm persist; then
          echo "power: bclm persist failed." >&2
        fi
      fi
    elif [ -d "$battery_app" ]; then
      echo "power: battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command." >&2
    else
      echo "power: no supported battery charge-limit tool found (expected /usr/local/bin/battery or /opt/homebrew/bin/bclm)." >&2
    fi

    # ---- configureLinearMousePreferences --------------------------------------
    # Keep LinearMouse update checks and auto-update disabled declaratively.
    # These are Sparkle preferences in the app's defaults domain.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if [ -d "/Applications/LinearMouse.app" ]; then
        console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
        if [ -n "$console_uid" ]; then
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUEnableAutomaticChecks -bool false; then
            echo "linearmouse: failed to disable automatic update checks for user '$console_user'." >&2
          fi
          if ! /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/defaults write com.lujjjh.LinearMouse SUAutomaticallyUpdate -bool false; then
            echo "linearmouse: failed to disable automatic updates for user '$console_user'." >&2
          fi
        fi
      fi
    fi
    # ---- configureGimpScrollSensitivity ---------------------------------------
    # Reduce GIMP zoom sensitivity to 25% of upstream default by setting the
    # drag-zoom-speed token in the active user gimprc to 25.0 (default 100.0).
    #
    # Why this token: GIMP upstream exposes drag-zoom-speed as a persisted
    # display config token.  Mouse-wheel zoom on macOS uses native scroll
    # deltas and does not have an equivalent persisted sensitivity token.
    # This hook therefore converges the closest supported persistent control.
    #
    # Version tracking rule: always target the major.minor branch of the GIMP
    # app provisioned by Nucleus (/Applications/GIMP.app), rather than using a
    # hardcoded version list, so new app upgrades keep working automatically.
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
      if [ -z "$console_home" ]; then
        console_home="/Users/$console_user"
      fi

      console_group="$(/usr/bin/id -gn "$console_user" 2>/dev/null || true)"

      gimp_app_info="/Applications/GIMP.app/Contents/Info"
      gimp_version_raw=""
      if [ -d "/Applications/GIMP.app" ]; then
        gimp_version_raw="$(/usr/bin/defaults read "$gimp_app_info" CFBundleShortVersionString 2>/dev/null || true)"
      fi

      # Derive major.minor branch used by GIMP's config directory layout,
      # e.g. 3.2.4 -> 3.2
      gimp_version_branch="$(printf '%s' "$gimp_version_raw" | /usr/bin/awk -F. 'NF >= 2 { print $1 "." $2 }')"
      if [ -z "$gimp_version_branch" ]; then
        echo "gimp: unable to determine installed GIMP major.minor version from /Applications/GIMP.app; skipping sensitivity convergence." >&2
      else
        gimprc_dir="$console_home/Library/Application Support/GIMP/$gimp_version_branch"
        gimprc_file="$gimprc_dir/gimprc"

        if ! /bin/mkdir -p "$gimprc_dir"; then
          echo "gimp: failed to create $gimprc_dir." >&2
        else
          if [ ! -f "$gimprc_file" ]; then
            if ! /usr/bin/touch "$gimprc_file"; then
              echo "gimp: failed to create $gimprc_file." >&2
            fi
          fi

          if [ -f "$gimprc_file" ]; then
            # Keep all other user settings intact: only replace or append the
            # drag-zoom-speed token.
            if /usr/bin/grep -Eq '^\(drag-zoom-speed[[:space:]]+[^)]*\)$' "$gimprc_file"; then
              if ! /usr/bin/sed -E -i.bak 's#^\(drag-zoom-speed[[:space:]]+[^)]*\)$#(drag-zoom-speed 25.0)#' "$gimprc_file"; then
                echo "gimp: failed to update drag-zoom-speed in $gimprc_file." >&2
              fi
              /bin/rm -f "$gimprc_file.bak"
            else
              if ! printf '\n(drag-zoom-speed 25.0)\n' >> "$gimprc_file"; then
                echo "gimp: failed to append drag-zoom-speed to $gimprc_file." >&2
              fi
            fi

            if [ -n "$console_group" ]; then
              if ! /usr/sbin/chown "$console_user:$console_group" "$gimprc_file"; then
                echo "gimp: failed to set ownership on $gimprc_file." >&2
              fi
            else
              if ! /usr/sbin/chown "$console_user" "$gimprc_file"; then
                echo "gimp: failed to set ownership on $gimprc_file." >&2
              fi
            fi
          fi
        fi
      fi
    fi

    # ---- configureMissionControlSpansDisplays ----------------------------------
    # Forces Mission Control to span desktops across displays for the currently
    # logged-in console user.  Applying this from system activation ensures the
    # preference is re-asserted after migrations and major macOS updates that
    # sometimes reset com.apple.spaces user defaults.
    #
    # Algorithm:
    #   1. Resolve the active console UID from /dev/console.
    #   2. Skip when no non-root GUI session is present (e.g. headless rebuild).
    #   3. Use launchctl asuser to write the per-user defaults domain as that user.
    console_uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"

    if [ -z "$console_uid" ] || [ "$console_uid" -eq 0 ]; then
      echo "power: no active non-root console user; skipping spans-displays write." >&2
    else
      if ! /bin/launchctl asuser "$console_uid" /usr/bin/defaults write com.apple.spaces spans-displays -bool true; then
        echo "power: failed to enable Mission Control spans-displays for console uid $console_uid." >&2
      fi
    fi

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
    # Clears Finder's saved application state cache so that desktop visibility
    # settings (ShowExternalHardDrivesOnDesktop, ShowHardDrivesOnDesktop,
    # ShowMountedServersOnDesktop, ShowRemovableMediaOnDesktop) take effect
    # immediately. Without this, Finder may display a stale cached state even
    # when system.defaults has been correctly updated. The cache file is
    # automatically regenerated by Finder on next launch with current defaults.
    #
    # WHY: Finder's cached state can become stale or corrupted, causing it to
    # ignore system default changes. Clearing it on every apply ensures the
    # live system state matches declared configuration without requiring manual
    # user intervention (Cmd+Opt+Esc, cache deletion, etc.).
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      finder_cache_dir="/Users/$console_user/Library/Saved Application State/com.apple.finder.savedState"
      if [ -d "$finder_cache_dir" ]; then
        if /bin/rm -rf "$finder_cache_dir"; then
          echo "finder: cleared cached application state from $finder_cache_dir"
        else
          echo "finder: failed to clear cached state at $finder_cache_dir (non-fatal; user may need manual restart)." >&2
        fi
      fi
      # Relaunch Finder so it picks up the cleared cache and current defaults.
      # Use killall to terminate the process; macOS will auto-relaunch it.
      /usr/bin/killall -9 Finder 2>/dev/null || true
    fi

      # ---- disableSpotlight -------------------------------------------------------
      # Completely disable Spotlight (command-palette/search engine) so Raycast
      # becomes the exclusive launcher. This requires system-level activation since
      # keyboard hotkey disabling needs root privileges.
      #
      # Four-layer disabling strategy:
      #   1. Hotkey 61 (cmd+space) — written to the user's prefs domain via
      #      launchctl asuser + sudo; applied immediately with activateSettings.
      #   2. Indexing daemon — stopped via mdutil (may need Full Disk Access)
      #   3. Launchd service — disabled for the user's GUI session (gui/$UID)
      #   4. Index cache — cleared to reclaim disk space
      #
      # WHY launchctl asuser for defaults write: the activation runs as root;
      # writing defaults without the asuser wrapper targets root's prefs domain
      # (/var/root/Library/Preferences/) instead of the user's domain, so the
      # hotkey change has no effect on the GUI session.
      # WHY activateSettings: applies keyboard shortcut changes immediately
      # without a restart or logout.
      # WHY gui/$console_uid_spotlight: Spotlight runs in the user's GUI session;
      # gui/0 targets root's GUI session which is never the correct target.

      echo "spotlight: disabling Spotlight (system launcher) to use Raycast exclusively..."

      # Write cmd+space hotkey disable as the GUI user so it lands in the correct
      # user-scoped preferences domain, then apply immediately with activateSettings.
      console_uid_spotlight="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
      if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ -n "$console_uid_spotlight" ]; then
        if ! /bin/launchctl asuser "$console_uid_spotlight" /usr/bin/sudo -H -u "$console_user" \
          /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 61 \
          "<dict><key>enabled</key><false/></dict>" 2>/dev/null; then
          echo "spotlight: warning — failed to write cmd+space hotkey disable for user '$console_user' (may require Full Disk Access)." >&2
        else
          # Apply keyboard shortcut changes immediately for the current GUI session.
          # WHY 2>/dev/null: activateSettings may print a harmless warning on some macOS versions.
          /bin/launchctl asuser "$console_uid_spotlight" /usr/bin/sudo -H -u "$console_user" \
            /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || \
            echo "spotlight: note — keyboard shortcut changes will take effect after next login." >&2
        fi
      else
        echo "spotlight: skipped hotkey disable (no active non-root GUI session detected)." >&2
      fi

      # Disable Spotlight indexing via mdutil (may require Full Disk Access on modern macOS).
      # WHY sudo -n: prevents blocking on a password prompt if sudo re-prompts unexpectedly.
      if ! sudo -n mdutil -i off / 2>/dev/null; then
        echo "spotlight: warning — failed to disable Spotlight indexing (mdutil may require Full Disk Access)." >&2
      fi

      # Disable Spotlight launchd service using the correct user GUI session target.
      if [ -n "$console_uid_spotlight" ]; then
        if ! launchctl disable gui/"$console_uid_spotlight"/com.apple.Spotlight 2>/dev/null; then
          echo "spotlight: note — Spotlight launchd disable may require Full Disk Access; continuing." >&2
        fi
      else
        echo "spotlight: skipped launchd disable (could not determine user UID)." >&2
      fi

      # Clear Spotlight index cache to reclaim disk space.
      if [ -d "/.Spotlight-V100" ]; then
        if ! sudo -n rm -rf "/.Spotlight-V100" 2>/dev/null; then
          echo "spotlight: note — Spotlight cache removal skipped (would require elevated privileges)." >&2
        fi
      fi

      echo "spotlight: Spotlight disabling complete. Note: some changes take effect after reboot."
  '';
}
