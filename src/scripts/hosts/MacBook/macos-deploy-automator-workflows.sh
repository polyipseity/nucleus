#!/usr/bin/env bash
# Deploy macOS Automator workflow bundles.
# Consumes jq binary and workflow JSON array at activation time.
set -eu


_vsd_jq_bin="$1"
_vsd_current_workflows_json="$2"
_vsd_services_dir="$HOME/Library/Services"

while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_dir="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.dir')"
  _vsd_store_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.source')"
  _vsd_key="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.enablementKey')"
  _vsd_pm_dict="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.presentationModesDict')"

  _vsd_wf_dir="$_vsd_services_dir/$_vsd_dir"
  mkdir -p "$_vsd_services_dir"
  chmod -R +w "$_vsd_wf_dir" 2>/dev/null || true  # check-suppress:suppression_doc: dir may not exist on first apply
  rm -rf "$_vsd_wf_dir"
  cp -R "$_vsd_store_path" "$_vsd_services_dir/"

  # Enable in presentation_modes format (macOS 14+).
  # CFBundleIdentifier is set in each workflow's Info.plist.
  /usr/bin/defaults write pbs NSServicesStatus -dict-add "$_vsd_key" \
    "<dict><key>presentation_modes</key>$_vsd_pm_dict</dict>"
done < <(printf '%s\n' "$_vsd_current_workflows_json" | "$_vsd_jq_bin" -r -c '.[]')
