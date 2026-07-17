# ---- enableScreenSharing ---------------------------------------------------
# Enable macOS Screen Sharing (VNC/ARD protocol) as the remote-desktop server
# for this host.  macOS does not ship a native RDP server; Screen Sharing is
# the platform equivalent and is accessible from Microsoft Remote Desktop
# clients (which support connecting to Macs) as well as any VNC client.
# blockAllIncoming = false in the firewall config already permits the inbound
# VNC port (5900); no additional firewall rule is needed.
#
# nix-darwin does not expose a services.screensharing option in this version;
# the LaunchDaemon plist is already installed by macOS and just needs its
# Disabled override cleared.
#
# launchctl load -w writes to the override database.  When the daemon is
# already loaded, launchctl prints "Service already loaded" to stderr and may
# return non-zero — this is expected steady-state behaviour, not an error.
# Error suppression justification (all three conditions met):
#   (1) Expected and benign: the daemon being already loaded is normal
#       steady-state on an already-configured machine.
#   (2) WHY comment: see above.
#   (3) Checked afterward: launchctl list verifies the daemon is present in
#       the system service table so a genuine load failure (e.g. missing
#       plist) is still caught.
#
# undoc-supp: Screen Sharing daemon may already be loaded; launchctl load -w
# exits 1 for already-loaded services.
/bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true  # undoc-supp: Screen Sharing daemon may already be loaded; launchctl load -w exits 1 for already-loaded services.
if ! /bin/launchctl list com.apple.screensharing > /dev/null 2>&1; then
      echo "RDP: Screen Sharing daemon not listed after load; remote desktop may not be active." >&2
fi

# ---- wifiPrivateAddress ----------------------------------------------------
# macOS does not expose a CLI to configure per-network Private Wi-Fi Address
# (Fixed/Rotating/Off). The SystemConfiguration plist is SIP-protected and
# the airport binary was removed in Sequoia. Private Wi-Fi Address is
# enabled by default (Fixed per SSID) — each SSID gets a unique private MAC
# that stays stable across reconnects. To switch a network to Rotating mode
# (changes ~24h), use:
#   System Settings > Wi-Fi > [Network] > Private Wi-Fi Address > Rotating
_WIFI_IFACE=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | \
  /usr/bin/awk '/Wi-Fi|AirPort/{getline; gsub(/^Device: /,""); print; exit}')
if [ -n "$_WIFI_IFACE" ]; then
  _WIFI_MAC=$(/usr/sbin/networksetup -getmacaddress "$_WIFI_IFACE" 2>/dev/null | \
    /usr/bin/awk '{print $3}')
  echo "Wi-Fi ($_WIFI_IFACE): permanent HW MAC $_WIFI_MAC — Private Address active (Fixed per SSID by default)"
  echo "  Per-network Rotating mode: System Settings > Wi-Fi > [SSID] > Private Wi-Fi Address > Rotating"
fi
unset _WIFI_IFACE _WIFI_MAC
