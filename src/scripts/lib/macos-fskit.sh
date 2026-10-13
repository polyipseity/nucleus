# shellcheck shell=bash
# FSKit module state for the macFUSE file-system extension (macOS).
#
# FSKit's own enabled-module list is the signal macOS exposes to a script; it
# decides whether a macFUSE-dependent entry counts as present. A list without
# the module is how a disabled extension reads.
# ref: https://github.com/macfuse/macfuse/issues/1132
#
# The probe answers "unknown" when the macOS-only tools are absent, so a caller
# that must not act on macOS keeps its own host check.

[ -n "${_NUCLEUS_MACOS_FSKIT_SOURCED-}" ] && return
_NUCLEUS_MACOS_FSKIT_SOURCED=1

# WHY: FSKit's own list, not PluginKit. pkd rejects a file-system module outside
# a SIP-protected app, so a pluginkit probe reports macFUSE absent while its
# volumes mount fine.
fskit_settings_plist() {
  printf '%s/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist\n' "${HOME:-}"
}

# WHY: "unknown" for an unreadable list, never "disabled". A probe failure must
# not read as a missing module.
fskit_module_state() {
  local bundle_id="$1" plist listing
  [ -n "$bundle_id" ] || return 1
  plist="$(fskit_settings_plist)"
  if [ ! -r "$plist" ] || ! command -v plutil >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  if ! listing="$(plutil -p "$plist" 2>/dev/null)"; then
    printf 'unknown\n'
    return 0
  fi
  if printf '%s\n' "$listing" | grep -qF "\"$bundle_id\""; then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}
