# Verify all home-manager-managed launchd agents are registered with launchd
# after setupLaunchAgents runs.  On macOS 26, launchctl bootstrap can
# spuriously return "Bootstrap failed: 5: Input/output error" -- HM detects
# this but never retries, and subsequent activations skip unchanged agents.
#
# Uses $newGenPath (set by Home Manager activation).
set -eu

_gui_domain="gui/$(id -u)"
_gen_launchagents="$newGenPath/LaunchAgents"

if [ ! -d "$_gen_launchagents" ]; then
  verboseEcho "No LaunchAgents directory in new generation -- nothing to verify"
  exit 0
fi

for _plist in "$_gen_launchagents"/*.plist; do
  [ -f "$_plist" ] || continue
  _label="${_plist##*/}"
  _label="${_label%.plist}"

  if /bin/launchctl print "$_gui_domain/$_label" >/dev/null 2>&1; then
    verboseEcho "Agent '$_label' is registered with launchd"
    continue
  fi

  warnEcho "Agent '$_gui_domain/$_label' is NOT registered -- bootstrapping..."

  /bin/launchctl bootout "$_gui_domain/$_label" 2>/dev/null || true  # undoc-supp: agent may not be registered (that's why we're here), bootout expected to fail
  sleep 1

  if /bin/launchctl bootstrap "$_gui_domain" "$_plist"; then
    /bin/launchctl kickstart -p "$_gui_domain/$_label"
    verboseEcho "Agent '$_label' successfully bootstrapped and kickstarted"
  else
    warnEcho "Agent '$_label' bootstrap failed -- will be picked up at next login"
  fi
done
