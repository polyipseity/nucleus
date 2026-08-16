#!/usr/bin/env bash
# Provides a uniform CLI for listing, enabling, disabling, and verifying
# GUI/user app auto-start across hosts, driven by src/modules/apps.json
# (the canonical registry).  This mirrors nucleus-svc but targets login/boot
# auto-start apps rather than background daemons.
#
# Usage: nucleus-autostart <action> [app...] [options]
#   Actions: list, status, enable, disable, apply, verify.
#
# Policy (driving constraint): we never let an app manage its own startup.
# If an app exposes a native auto-start setting, we disable it (disableNative),
# then control enable/disable through exactly one uniform mechanism we own:
#   macOS   — login items we add/remove via osascript System Events
#             (system extensions use systemextensionsctl best-effort + manual)
#   NixOS   — an XDG autostart .desktop we write/remove
#   Windows — a Run-key entry or Startup-folder .lnk we write/remove
#
# Prerequisites: apps.json in the repo; jq; osascript (macOS) or the relevant
# platform tooling.  Exit conditions: non-zero when an app name does not
# resolve, an action fails, or verify finds a disabled app that is still
# starting (or an enabled app that is not).

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
  /*) _self="$_target" ;;
  *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
. "$SCRIPT_DIR/../src/scripts/lib/macos-console-user.sh"

usage() {
  usage_std "$(basename "$0")" "list|status|enable|disable|apply|verify [app...] [options]"
  cat <<'EOF'
  list                       List all known apps with auto-start status.
  status [app...]            Show auto-start status of specified apps (all if omitted).
  enable <app>               Enable auto-start for the app (our uniform mechanism).
  disable <app>              Disable auto-start for the app.
  apply                      Converge every app to its registry-declared state.
  verify [app...]            Check declared vs actual state; warn on drift.
  --json                     Machine-readable JSON output.
  -h|--help                  Show usage.
EOF
}

REPO_ROOT="$(derive_repo_root)"
APPS_JSON="$REPO_ROOT/src/modules/apps.json"
HOST="$(resolve_nucleus_host)"

case "$HOST" in
MacBook | NixOS | Windows) ;;
*) error "unsupported host '$HOST'" ;;
esac

# read_registry — Parse apps.json and return JSON filtered to current host.
# Output: compact JSON on stdout; exits non-zero if the file or jq is missing.
read_registry() {
  if [ ! -f "$APPS_JSON" ]; then
    error "app registry not found at $APPS_JSON"
  fi
  require_command jq
  jq -c --arg host "$HOST" '
    to_entries | map(
      select(.key | startswith("$") | not)
      | select(.value | type == "object")
      | select(.value.hosts | has($host))
      | select(.value.hosts[$host].type != "omitted")
      | {key: .key, value: {
          displayName: .value.displayName,
          description: .value.description,
          hostEntry: .value.hosts[$host]
        }}
    ) | from_entries
  ' "$APPS_JSON"
}

# ──────────────────────────────────────────────────────────────────────────────
# macOS login-item helpers (run as the console user)
# ──────────────────────────────────────────────────────────────────────────────

# macos_login_item_exists NAME — stdout "true"/"false".
macos_login_item_exists() {
  local name="$1"
  _nucleus_resolve_console_user || { printf 'false'; return 0; }
  /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/osascript \
    -e 'tell application "System Events"' \
    -e "exists login item \"$name\"" \
    -e 'end tell' 2>/dev/null | grep -qx 'true' && printf 'true' || printf 'false'
}

# macos_login_item_ensure NAME PATH HIDDEN — add (idempotent) our login item.
macos_login_item_ensure() {
  local name="$1" path="$2" hidden="$3"
  _nucleus_resolve_console_user || return 0
  /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/osascript \
    -e 'tell application "System Events"' \
    -e "if not (exists login item \"$name\") then" \
    -e "make login item at end with properties {name:\"$name\", path:\"$path\", hidden:$hidden}" \
    -e 'end if' \
    -e 'end tell' 2>/dev/null
}

# macos_login_item_remove NAME — delete any login item with this name.
macos_login_item_remove() {
  local name="$1"
  _nucleus_resolve_console_user || return 0
  /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
    /usr/bin/osascript \
    -e 'tell application "System Events"' \
    -e "if exists login item \"$name\" then" \
    -e "delete login item \"$name\"" \
    -e 'end if' \
    -e 'end tell' 2>/dev/null
}

# macos_system_extension_present ID — stdout "true"/"false" via systemextensionsctl.
macos_system_extension_present() {
  local bundle_id="$1"
  if command -v systemextensionsctl >/dev/null 2>&1; then
    systemextensionsctl list 2>/dev/null | grep -q "$bundle_id" && printf 'true' || printf 'false'
  else
    printf 'false'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Per-app state resolution
# ──────────────────────────────────────────────────────────────────────────────

# app_login_item_name — Derive the login item name for an app entry.
# Uses displayName (matches how macOS labels login items); falls back to key.
app_login_item_name() {
  local key="$1" entry_json="$2"
  echo "$entry_json" | jq -r '.displayName // empty' | head -1
  [ -z "$(echo "$entry_json" | jq -r '.displayName // empty')" ] && printf '%s' "$key"
}

# app_actual_state KEY ENTRY_JSON — stdout "enabled"/"disabled"/"unknown".
# Reflects whether OUR uniform mechanism currently has the app starting.
app_actual_state() {
  local key="$1" entry_json="$2"
  local kind
  kind=$(echo "$entry_json" | jq -r '.hostEntry.kind')
  case "$kind" in
  login-item)
    local name path
    name=$(app_login_item_name "$key" "$entry_json")
    path=$(echo "$entry_json" | jq -r '.hostEntry.path // empty')
    if [ "$(macos_login_item_exists "$name")" = "true" ]; then
      printf 'enabled'
    else
      printf 'disabled'
    fi
    ;;
  system-extension)
    local bundle_id
    bundle_id=$(echo "$entry_json" | jq -r '.hostEntry.bundleId // empty')
    if [ -n "$bundle_id" ] && [ "$(macos_system_extension_present "$bundle_id")" = "true" ]; then
      printf 'enabled'
    else
      printf 'disabled'
    fi
    ;;
  *)
    printf 'unknown'
    ;;
  esac
}

# app_converge KEY ENTRY_JSON — Apply declared state for one app.
# disableNative first neutralizes the app's own native auto-start (so only our
# mechanism remains), then we add/remove our login item per `enabled`.
app_converge() {
  local key="$1" entry_json="$2"
  local kind enabled disable_native name path hidden
  kind=$(echo "$entry_json" | jq -r '.hostEntry.kind')
  enabled=$(echo "$entry_json" | jq -r '.hostEntry.enabled')
  disable_native=$(echo "$entry_json" | jq -r '.hostEntry.disableNative')
  name=$(app_login_item_name "$key" "$entry_json")
  path=$(echo "$entry_json" | jq -r '.hostEntry.path // empty')
  hidden=$(echo "$entry_json" | jq -r '.hostEntry.hidden // false')

  case "$kind" in
  login-item)
    if [ "$disable_native" = "true" ]; then
      # Neutralize any app-owned login item (our mechanism and the app's
      # native checkbox both manifest as a login item with this name).
      macos_login_item_remove "$name" || true # check-suppress:suppression_doc: login item may already be absent; removal is best-effort before re-adding our own.
    fi
    if [ "$enabled" = "true" ]; then
      macos_login_item_ensure "$name" "$path" "$hidden" || warn -l "$key" "failed to ensure login item"
    else
      macos_login_item_remove "$name" || true # check-suppress:suppression_doc: login item may already be absent; removal is best-effort.
    fi
    ;;
  system-extension)
    # System extensions cannot be enabled/disabled from the shell; approval is
    # manual in System Settings → Privacy & Security.  Surface a reminder and
    # report actual presence; never pretend we forced the state.
    local bundle_id
    bundle_id=$(echo "$entry_json" | jq -r '.hostEntry.bundleId // empty')
    if [ "$enabled" = "true" ]; then
      if [ -n "$bundle_id" ] && [ "$(macos_system_extension_present "$bundle_id")" = "true" ]; then
        say -l "$key" "system extension present (approved in System Settings)."
      else
        warn -l "$key" "system extension not yet approved — enable it in System Settings → Privacy & Security, then approve the extension."
      fi
    fi
    ;;
  *)
    warn -l "$key" "unsupported kind '$kind' on host '$HOST'"
    return 1
    ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Action implementations
# ──────────────────────────────────────────────────────────────────────────────

do_list() {
  local registry
  registry=$(read_registry)
  if [ "$json_output" = true ]; then
    local out=""
    while IFS=$'\t' read -r key display entry_json; do
      local state
      state=$(app_actual_state "$key" "$entry_json")
      local declared
      declared=$(echo "$entry_json" | jq -r '.hostEntry.enabled')
      local pair
      pair=$(jq -cn --arg k "$key" --argjson v "$(jq -cn --arg s "$state" --argjson d "$declared" '{state:$s, declaredEnabled:$d}')" '{key:$k, value:$v}')
      out="${out:+$out
}$pair"
    done < <(echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value | tojson)] | @tsv')
    printf '%s\n' "$out" | jq -c -s 'reduce .[] as $i ({}; .[$i.key] = $i.value) | {version: 1, apps: .}'
  else
    printf '%-22s %-10s %-8s %s\n' "ID" "State" "Declared" "Name"
    printf '%.0s-' {1..70}
    printf '\n'
    while IFS=$'\t' read -r key display entry_json; do
      local state declared
      state=$(app_actual_state "$key" "$entry_json")
      declared=$(echo "$entry_json" | jq -r '.hostEntry.enabled')
      printf '%-22s %-10s %-8s %s\n' "$key" "$state" "$declared" "$display"
    done < <(echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value | tojson)] | @tsv')
  fi
}

do_status() {
  if [ "$json_output" = true ]; then
    do_list
    return
  fi
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_app_names "$registry" "${app_names[@]}")
  while IFS=$'\t' read -r key display entry_json; do
    if echo "$key" | grep -q '^ERROR:'; then
      warn "${key#ERROR:} — $(echo "$entry_json" | jq -r '.error // "app not found"')"
      continue
    fi
    local state
    state=$(app_actual_state "$key" "$entry_json")
    printf '%-22s %-10s %s\n' "$key" "$state" "$display"
  done <<<"$entries"
}

do_enable() { do_set enabled true; }
do_disable() { do_set enabled false; }

# do_set — Enable or disable a named app's auto-start via our mechanism.
do_set() {
  local value="$1"
  if [ "${#app_names[@]}" -eq 0 ]; then
    error "missing app name for $action"
  fi
  local registry
  registry=$(read_registry)
  local overall=0
  for app in "${app_names[@]}"; do
    local entry
    entry=$(echo "$registry" | jq -c --arg name "$app" '.[$name] // empty')
    if [ -z "$entry" ]; then
      warn "$app — app not found in registry"
      overall=1
      continue
    fi
    # Override the declared `enabled` with the requested action for this run.
    local overridden
    overridden=$(echo "$entry" | jq --argjson v "$value" '.hostEntry.enabled = $v')
    if ! app_converge "$app" "$overridden"; then
      warn "$app — $action failed"
      overall=1
    fi
  done
  return "$overall"
}

do_apply() {
  local registry
  registry=$(read_registry)
  local overall=0
  while IFS=$'\t' read -r key display entry_json; do
    if ! app_converge "$key" "$entry_json"; then
      overall=1
    fi
  done < <(echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value | tojson)] | @tsv')
  return "$overall"
}

do_verify() {
  local registry
  registry=$(read_registry)
  local entries
  entries=$(resolve_app_names "$registry" "${app_names[@]}")
  local drift=false
  while IFS=$'\t' read -r key display entry_json; do
    if echo "$key" | grep -q '^ERROR:'; then continue; fi
    local declared actual
    declared=$(echo "$entry_json" | jq -r '.hostEntry.enabled')
    actual=$(app_actual_state "$key" "$entry_json")
    if { [ "$declared" = "true" ] && [ "$actual" != "enabled" ]; } || \
       { [ "$declared" = "false" ] && [ "$actual" != "disabled" ]; }; then
      drift=true
      warn "$key — drift: declared enabled=$declared, actual=$actual"
    fi
  done <<<"$entries"
  if $drift; then
    return 1
  fi
  say "all apps converged to declared state"
}

# resolve_app_names — Resolve requested names to registry entries.
# Output: tab lines key\tdisplay\tentryJson.  Unknown names → ERROR: rows.
resolve_app_names() {
  local registry="$1"
  shift
  local names=("$@")
  if [ "${#names[@]}" -eq 0 ]; then
    echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value | tojson)] | @tsv'
    return
  fi
  for name in "${names[@]}"; do
    local entry
    entry=$(echo "$registry" | jq -c --arg name "$name" '.[$name] // empty')
    if [ -n "$entry" ]; then
      printf '%s\n' "$name	$(echo "$entry" | jq -r '.displayName')	$entry"
    else
      printf '%s\n' "ERROR:unknown	$name	{\"error\":\"app not found in registry\"}"
    fi
  done
}

# Main

json_output=false
action=""
app_names=()

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --json)
    json_output=true
    shift
    ;;
  list | status | enable | disable | apply | verify)
    action="$1"
    shift
    app_names=("$@")
    break
    ;;
  *)
    error "unsupported argument '$1'"
    usage >&2
    exit 1
    ;;
  esac
done

[ -z "$action" ] && {
  error "missing action (list, status, enable, disable, apply, verify)"
  usage >&2
  exit 1
}

case "$action" in
list) do_list ;;
status) do_status ;;
enable) do_enable ;;
disable) do_disable ;;
apply) do_apply ;;
verify) do_verify ;;
esac
