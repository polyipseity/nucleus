#!/usr/bin/env bash
# ---- enableScreenSharing ---------------------------------------------------
# macOS has no native RDP server, so Screen Sharing (VNC/ARD) is the
# remote-desktop equivalent and Microsoft Remote Desktop clients can reach it.
# blockAllIncoming = false in the firewall config already permits 5900.
#
# nix-darwin exposes no services.screensharing option here, so the plist macOS
# installs itself only needs its Disabled override cleared.
#
# WHY the exit status is ignored: launchctl load -w prints "Service already
#   loaded" to stderr and may exit non-zero once the daemon is loaded, which is
#   steady state, not failure. The launchctl list check below still catches a
#   genuine load failure such as a missing plist.
#
# check-suppress:suppression_doc: Screen Sharing daemon may already be loaded; launchctl load -w
# exits 1 for already-loaded services.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

/bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true # check-suppress:suppression_doc: Screen Sharing daemon may already be loaded; launchctl load -w exits 1 for already-loaded services.
if ! /bin/launchctl list com.apple.screensharing >/dev/null 2>&1; then
  # check-suppress:suppression_doc: verification-only; load already succeeded, this is a post-load sanity note
  warn -l rdp "Screen Sharing daemon not listed after load; remote desktop may not be active."
fi

# ---- wifiPrivateAddress ----------------------------------------------------
# No CLI configures per-network Private Wi-Fi Address: the SystemConfiguration
# plist is SIP-protected and the airport binary was removed in Sequoia. It is
# on by default (Fixed per SSID), so each SSID keeps one stable private MAC. To
# switch a network to Rotating (~24h):
#   System Settings > Wi-Fi > [Network] > Private Wi-Fi Address > Rotating
_WIFI_IFACE=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null |
  /usr/bin/awk '/Wi-Fi|AirPort/{getline; gsub(/^Device: /,""); print; exit}')
if [ -n "$_WIFI_IFACE" ]; then
  _WIFI_MAC=$(/usr/sbin/networksetup -getmacaddress "$_WIFI_IFACE" 2>/dev/null |
    /usr/bin/awk '{print $3}')
  say -l "wi-fi" "$_WIFI_IFACE: permanent HW MAC $_WIFI_MAC — Private Address active (Fixed per SSID by default)"
  say -l "wi-fi" "$_WIFI_IFACE: Per-network Rotating mode: System Settings > Wi-Fi > [SSID] > Private Wi-Fi Address > Rotating"
fi
unset _WIFI_IFACE _WIFI_MAC
