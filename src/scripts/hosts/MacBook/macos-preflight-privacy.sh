# Preflight macOS privacy permissions before defaults writes.
# Token __FDA_LIB__ is replaced with the FDA warning library (with
# __FDA_TARGET__ resolved by the Nix caller).
set -eu

echo "macos: checking macOS privacy permissions before defaults writes..." >&2

fda_warning_emitted=0
__FDA_LIB__

probe_domain="com.apple.universalaccess"
probe_key="NucleusActivationProbe"
if ! probe_err="$({
  /usr/bin/defaults write "$probe_domain" "$probe_key" -bool false
  /usr/bin/defaults delete "$probe_domain" "$probe_key"
} 2>&1)"; then
  if printf '%s' "$probe_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
    print_fda_warning
  else
    echo "macos: privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes." >&2
  fi
fi
