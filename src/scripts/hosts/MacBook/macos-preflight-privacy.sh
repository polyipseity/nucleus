# Preflight macOS privacy permissions before defaults writes.
# Full Disk Access privacy preflight. Runs FDA checks before defaults writes.
# __REPO_ROOT__ is substituted at build time by Nix (replaceStrings).
set -eu

echo "macos: checking macOS privacy permissions before defaults writes..." >&2

. "__REPO_ROOT__/src/scripts/lib/macos-fda-warning-lib.sh"

fda_warning_emitted=0

probe_domain="com.apple.universalaccess"
probe_key="NucleusActivationProbe"
if ! probe_err="$({
  /usr/bin/defaults write "$probe_domain" "$probe_key" -bool false
  /usr/bin/defaults delete "$probe_domain" "$probe_key"
} 2>&1)"; then
  if printf '%s' "$probe_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
    print_fda_warning "protected user preferences"
  else
    echo "macos: privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes." >&2
  fi
fi
