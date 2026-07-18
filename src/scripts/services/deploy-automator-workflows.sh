# Deploy and prune macOS Automator workflow bundles.
# Consumes __JQ_BIN__, __CURRENT_WORKFLOWS_JSON__, __REMOVED_WORKFLOWS_JSON__.
# Expects set -eu to be sourced before this script runs.
set -eu

_vsd_jq_bin='__JQ_BIN__'
_vsd_current_workflows_json='__CURRENT_WORKFLOWS_JSON__'
_vsd_removed_workflows_json='__REMOVED_WORKFLOWS_JSON__'
_vsd_services_dir="$HOME/Library/Services"

# ── Phase 1b: Prune removed Automator workflows ────────────────────
# First pass: delete all NSServicesStatus keys (entries may or may not have dir).
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_key="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.enablementKey')"
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$_vsd_key\"" \
    ~/Library/Preferences/pbs.plist 2>/dev/null || true  # undoc-supp: key may not exist on first apply
  # Second pass: remove workflow dirs for entries that have one.
  _vsd_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.dir // empty')"
  if [ -n "$_vsd_dir" ]; then
    _vsd_wf_path="$_vsd_services_dir/$_vsd_dir"
    if [ -d "$_vsd_wf_path" ]; then
      chmod -R +w "$_vsd_wf_path" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
      rm -rf "$_vsd_wf_path"
    fi
  fi
done < <(printf '%s\n' "$_vsd_removed_workflows_json" | "$_vsd_jq_bin" -r -c '.[]')

# ── Phase 3: Deploy Automator workflows (in declaration order) ────
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.dir')"
  _vsd_store_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.source')"
  _vsd_key="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.enablementKey')"
  _vsd_pm_dict="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.presentationModesDict')"

  _vsd_wf_dir="$_vsd_services_dir/$_vsd_dir"
  mkdir -p "$_vsd_services_dir"
  chmod -R +w "$_vsd_wf_dir" 2>/dev/null || true  # undoc-supp: dir may not exist on first apply
  rm -rf "$_vsd_wf_dir"
  cp -R "$_vsd_store_path" "$_vsd_services_dir/"

  # Enable in presentation_modes format (macOS 14+).
  # CFBundleIdentifier is set in each workflow's Info.plist.
  /usr/bin/defaults write pbs NSServicesStatus -dict-add "$_vsd_key" \
    "<dict><key>presentation_modes</key>$_vsd_pm_dict</dict>"
done < <(printf '%s\n' "$_vsd_current_workflows_json" | "$_vsd_jq_bin" -r -c '.[]')
