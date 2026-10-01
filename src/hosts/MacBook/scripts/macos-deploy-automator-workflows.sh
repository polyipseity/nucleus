#!/usr/bin/env bash
# Deploy macOS Automator workflow bundles. jq, the workflow JSON array, setIcon,
# defaults and mdimport arrive as arguments so the script can run end to end
# against stub binaries in tests.
set -eu

_vsd_jq_bin="$1"
_vsd_current_workflows_json="$2"
_vsd_set_icon_bin="$3"
_vsd_defaults_bin="$4"
_vsd_mdimport_bin="$5"
_vsd_services_dir="$HOME/Library/Services"

# Phase 1: copy workflows, register icons, build the NSServicesStatus plist XML.
# The dictionary is written in one `defaults write` at the end because
# `defaults write -dict-add` cannot parse keys with spaces or parentheses: its
# parser splits on spaces regardless of shell quoting.
_vsd_nss_dict=""

# Pruning is what makes a renamed or removed preset disappear: macOS
# re-registers an NSServicesStatus entry for every bundle left in
# ~/Library/Services, so a leftover keeps its old Finder label even after the
# dictionary rewrite drops its enablement key. Only bundles whose readable
# CFBundleIdentifier is com.nucleus.* are removed.
#
# The declared set is the workflow list for this activation, so anything else in
# ~/Library/Services is a leftover from an earlier preset set.
automator_prune_stale_workflows() {
  local services_dir="$1" desired_dirs_file="$2" defaults_bin="$3"
  local installed installed_name installed_id
  for installed in "$services_dir"/*.workflow; do
    [ -e "$installed" ] || continue
    installed_name="${installed##*/}"
    if grep -qxF -- "$installed_name" "$desired_dirs_file"; then
      continue
    fi
    # check-suppress:suppression_doc: a bundle with no readable CFBundleIdentifier is not provably ours; it stays.
    installed_id="$("$defaults_bin" read "$installed/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    case "$installed_id" in
    com.nucleus.*) rm -rf "$installed" ;;
    esac
  done
}

# The declared set is the workflow list for this activation, so anything else in
# ~/Library/Services is a leftover from an earlier preset set.
_vsd_desired_dirs_file="$(mktemp)"
trap 'rm -f "$_vsd_desired_dirs_file"' EXIT
printf '%s\n' "$_vsd_current_workflows_json" | "$_vsd_jq_bin" -r '.[].dir' >"$_vsd_desired_dirs_file"
automator_prune_stale_workflows "$_vsd_services_dir" "$_vsd_desired_dirs_file" "$_vsd_defaults_bin"

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

  # Register Thumbnail.png with IconServices so Finder shows the SF Symbol icon.
  "$_vsd_set_icon_bin" "$_vsd_wf_dir/Contents/QuickLook/Thumbnail.png" "$_vsd_wf_dir"
  "$_vsd_mdimport_bin" "$_vsd_wf_dir"

  # Accumulate this workflow's enablement entry into the NSServicesStatus dict.
  # Key text is XML-escaped: spaces and parens are safe, but < > & are not.
  _vsd_nss_dict+="<key>${_vsd_key}</key><dict><key>presentation_modes</key>${_vsd_pm_dict}</dict>"
done < <(printf '%s\n' "$_vsd_current_workflows_json" | "$_vsd_jq_bin" -r -c '.[]')

# Phase 2: write the complete NSServicesStatus dictionary in one shot.
# CFBundleIdentifier is set in each workflow's Info.plist.
"$_vsd_defaults_bin" write pbs NSServicesStatus "<dict>${_vsd_nss_dict}</dict>"
