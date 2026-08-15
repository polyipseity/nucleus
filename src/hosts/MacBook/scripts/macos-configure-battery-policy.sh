#!/usr/bin/env bash
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
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

apply_pmset() {
  if ! /usr/bin/pmset "$@"; then
    error -l power "failed to apply pmset settings: $*"
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
