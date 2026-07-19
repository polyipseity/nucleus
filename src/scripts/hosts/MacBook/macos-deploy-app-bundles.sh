# Deploy and prune macOS app bundles via LaunchServices.
# Tokens are substituted at build time by Nix.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

# Source library helpers (provides LSREGISTER, APP_DIR).
. "$SCRIPT_DIR/../../lib/macos-app-bundle-lib.sh"

_vsd_jq_bin='__JQ_BIN__'
_vsd_removed_bundles_json='__REMOVED_BUNDLES_JSON__'
_vsd_current_bundles_json='__CURRENT_BUNDLES_JSON__'

# ── Phase 1a: Prune removed app bundles ───────────────────────────
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_app_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.appDir')"
  _vsd_bundle_id="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.bundleId')"
  _vsd_menu_item="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.menuItem')"
  _vsd_message="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.message')"

  # Delete NSServicesStatus key unconditionally.
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$_vsd_bundle_id - $_vsd_menu_item - $_vsd_message\"" \
    ~/Library/Preferences/pbs.plist 2>/dev/null || true  # undoc-supp: key may not exist on first apply

  _vsd_app_path="$APP_DIR/$_vsd_app_dir"
  if [ -d "$_vsd_app_path" ]; then
    "$LSREGISTER" -u "$_vsd_app_path" 2>/dev/null || true  # undoc-supp: app may not be deployed yet
    chmod -R +w "$_vsd_app_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
    rm -rf "$_vsd_app_path"
  fi
done < <(printf '%s\n' "$_vsd_removed_bundles_json" | "$_vsd_jq_bin" -r -c '.[]')

# ── Phase 2: Deploy app bundles (in declaration order) ────────────
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_app_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.appDir')"
  _vsd_store_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.source')"
  _vsd_bundle_id="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.bundleId')"
  _vsd_menu_item="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.menuItem')"
  _vsd_message="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.message')"
  _vsd_pm_dict="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.presentationModesDict')"

  _vsd_app_path="$APP_DIR/$_vsd_app_dir"
  mkdir -p "$APP_DIR"
  # Nix store outputs are read-only; strip that before deletion to avoid
  # Permission denied on the next generation switch.
  chmod -R +w "$_vsd_app_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
  rm -rf "$_vsd_app_path"
  cp -R "$_vsd_store_path" "$APP_DIR/"

  "$LSREGISTER" -R -f "$_vsd_app_path" || true  # undoc-supp: LaunchServices may reject unsigned bundles; not fatal

  # Enable the service in NSServicesStatus so it appears in the Services
  # menu and right-click context menu without manual toggling in
  # System Settings > Extensions > Services.
  # Service key format: "<NSBundleIdentifier> - <NSMenuItem.default> - <NSMessage>"
  # Uses presentation_modes dict (macOS 14+) instead of legacy
  # enabled_context_menu/enabled_services_menu booleans.
  _vsd_enablement_key="$_vsd_bundle_id - $_vsd_menu_item - $_vsd_message"
  /usr/bin/defaults write pbs NSServicesStatus -dict-add "$_vsd_enablement_key" \
    "<dict><key>presentation_modes</key>$_vsd_pm_dict</dict>"
done < <(printf '%s\n' "$_vsd_current_bundles_json" | "$_vsd_jq_bin" -r -c '.[]')
