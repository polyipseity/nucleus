#!/usr/bin/env bash
# Deploy macOS Automator workflow bundles.
# Consumes jq binary, workflow JSON array, and setIcon binary path at activation time.
set -eu

_vsd_jq_bin="$1"
_vsd_current_workflows_json="$2"
_vsd_set_icon_bin="$3"
_vsd_services_dir="$HOME/Library/Services"

while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.dir')"
  _vsd_store_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.source')"
  _vsd_key="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.enablementKey')"
  _vsd_pm_dict="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.presentationModesDict')"

  _vsd_wf_dir="$_vsd_services_dir/$_vsd_dir"
  mkdir -p "$_vsd_services_dir"
  rm -rf "$_vsd_wf_dir"
  cp -R "$_vsd_store_path" "$_vsd_wf_dir"
  chmod -R u+w "$_vsd_wf_dir"

  # Register Thumbnail.png with IconServices so Finder shows the custom SF Symbol icon.
  "$_vsd_set_icon_bin" "$_vsd_wf_dir/Contents/QuickLook/Thumbnail.png" "$_vsd_wf_dir"
  /usr/bin/mdimport "$_vsd_wf_dir"

  # Enable in presentation_modes format (macOS 14+).
  # CFBundleIdentifier is set in each workflow's Info.plist.
  /usr/bin/defaults write pbs NSServicesStatus -dict-add "$_vsd_key" \
    "<dict><key>presentation_modes</key>$_vsd_pm_dict</dict>"
done < <(printf '%s\n' "$_vsd_current_workflows_json" | "$_vsd_jq_bin" -r -c '.[]')
