#!/usr/bin/env bash
# Enforce pmset values directly per power source because newer macOS releases can ignore or partially override higher-level power options.
#
# Keys NOT settable via the pmset CLI on this hardware (Apple Silicon, macOS 15+): "Sleep On Power Button" and "SleepServices". Both appear in `pmset -g` output but are absent from `pmset -g cap` and rejected with a usage error when written, so the OS and firmware own them. Sleep-on-button is set by hand in System Settings; SleepServices follows powernap=1.
#
# womp=1 on both sources: pmset -g custom confirms the machine honours womp on battery, so setting it on both makes inbound magic-packet wakes succeed regardless of power source.
#
# sleep=0 on battery: remote-desktop sessions (Chrome Remote Desktop, VNC/ARD, SSH) must survive on battery, and idle sleep would disconnect active sessions and block new inbound connections.
#
# displaysleep and disksleep are declared on both sources even with lowpowermode=1 on battery, because pmset -g custom confirms all three battery values are honoured once they are applied after the lowpowermode preset.
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
  # pmset -g cap rarely fails on a live system, so stderr is suppressed to keep an unsupported-capability probe quiet; any real pmset failure surfaces when apply_pmset later writes the value.
  /usr/bin/pmset -g cap 2>/dev/null | /usr/bin/grep -Eq "(^|[[:space:]])$capability([[:space:]]|$)"
}

if [ -x /usr/bin/pmset ]; then
  # WHY per-key rationale: ttyskeepawake keeps a live remote session from being dropped by an unexpected idle sleep while a network terminal holds a tty; hibernatemode 3 writes a RAM image to disk first so the session survives the battery draining during sleep; tcpkeepalive carries persistent SSH tunnels and remote-desktop sessions across sleep/wake without application-level keepalives.
  apply_pmset -a standby 1 ttyskeepawake 1 hibernatemode 3 networkoversleep 0 tcpkeepalive 1 powernap 1 lidwake 1
  # hibernatefile set separately: a path argument on the same line as other flag-value pairs is easy to misread as a flag rather than a path.
  apply_pmset -a hibernatefile /var/vm/sleepimage

  if pmset_supports lowpowermode; then
    # WHY: lowpowermode is set per source BEFORE the per-source timers, so any OS preset adjustments it triggers are then overridden by the explicit values below.
    apply_pmset -c lowpowermode 0
    apply_pmset -b lowpowermode 1
  fi

  # AC settings: 1-minute display sleep, no idle system sleep, no disk sleep.
  apply_pmset -c displaysleep 1 sleep 0 disksleep 0 womp 1

  # Battery settings: 1-minute display sleep, no idle system sleep, no disk sleep.
  apply_pmset -b displaysleep 1 sleep 0 disksleep 0 womp 1

  if pmset_supports lessbright; then
    # lessbright dims the display on battery to extend runtime, and there is no separate AC-source control for it.
    apply_pmset -b lessbright 1
  fi
fi
