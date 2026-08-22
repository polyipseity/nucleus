#!/usr/bin/env bash
# Provides a uniform CLI for listing, showing, hiding, and verifying menu-bar /
# tray icon visibility across hosts, driven by src/modules/apps.json (the
# canonical registry).  This mirrors nucleus-autostart but targets the app's
# native menu-bar / tray icon preference rather than auto-start.
#
# Usage: nucleus-menu-bar <action> [app...] [options]
#   Actions: list, status, show, hide, apply, verify.
#
# Semantic difference from auto-start (driving constraint):
#   Auto-start is OR — app-native OR our login item ⇒ app launches, so we
#   DISABLE the native setting and own a separate mechanism.
#   Icon visibility is AND — the icon shows only if (app-native show setting =
#   desired) AND (OS allows it). There is no separate "our mechanism"; the
#   app's native preference IS the control.  We therefore SET the native
#   preference to the desired state and never disable it.  Inverted keys
#   (e.g. BetterDisplay hideMenuIcon) are expressed via iconVisibleValue /
#   iconHiddenValue, not via a disable flag.
#
# Prerequisites: apps.json in the repo; jq; defaults (macOS) or the relevant
# platform tooling.  Exit conditions: non-zero when an app name does not
# resolve, an action fails, or verify finds drift.

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
. "$SCRIPT_DIR/lib/lib.sh"
. "$SCRIPT_DIR/lib/macos-console-user.sh"

usage() {
  usage_std "$(basename "$0")" "list|status|show|hide|apply|verify [app...] [options]"
  cat <<'EOF'
  list                       List all apps with a menuBarIcon block and their icon state.
  status [app...]            Show icon visibility of specified apps (all if omitted).
  show <app>                 Set the app's menu-bar / tray icon to visible.
  hide <app>                 Set the app's menu-bar / tray icon to hidden.
  apply                      Converge every app's icon to its registry-declared state.
  verify [app...]            Check declared vs actual icon state; warn on drift.
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

# read_registry — Parse apps.json and return JSON filtered to current host,
# keeping only entries that declare a menuBarIcon block.
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
      | select(.value.hosts[$host].menuBarIcon != null)
      | {key: .key, value: {
          displayName: .value.displayName,
          description: .value.description,
          hostEntry: .value.hosts[$host]
        }}
    ) | from_entries
  ' "$APPS_JSON"
}

# ──────────────────────────────────────────────────────────────────────────────
# macOS native preference helpers (run as the console user)
# ──────────────────────────────────────────────────────────────────────────────

# menu_bar_value_for VISIBLE ENTRY_JSON — stdout the native value to write
# (iconVisibleValue when visible, iconHiddenValue when hidden), typed per
# valueType.  Inverted keys are handled here, not by a disable flag.
menu_bar_value_for() {
  local visible="$1" entry_json="$2"
  local value_type
  value_type=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.valueType // "bool"')
  if [ "$visible" = "true" ]; then
    echo "$entry_json" | jq -r --arg t "$value_type" '.hostEntry.menuBarIcon.iconVisibleValue | if $t == "int" then tostring else tostring end'
  else
    echo "$entry_json" | jq -r --arg t "$value_type" '.hostEntry.menuBarIcon.iconHiddenValue | if $t == "int" then tostring else tostring end'
  fi
}

# menu_bar_native_set ENTRY_JSON VISIBLE — Write the native preference to the
# desired state.  Never disables the native setting; SETs it.  Manual entries
# (provisioned=false) are declared in config but not auto-provisioned; the gap
# is surfaced via list/verify, so we skip the SET and return 0.
menu_bar_native_set() {
  local entry_json="$1" visible="$2"
  local kind domain key plist_path value
  kind=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.kind')
  local provisioned
  provisioned=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.provisioned // true')
  if [ "$kind" = "manual" ] || [ "$provisioned" = "false" ]; then
    warn -l "$(echo "$entry_json" | jq -r '.displayName // "app"')" "manual icon entry; not auto-provisioned (set in the app's UI)"
    return 0
  fi
  value=$(menu_bar_value_for "$visible" "$entry_json")
  case "$kind" in
  defaults-key)
    domain=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.domain')
    key=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.key')
    local value_type
    value_type=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.valueType // "bool"')
    _nucleus_resolve_console_user || return 0
    local write_args=(-bool)
    case "$value_type" in
    string) write_args=(-string) ;;
    int) write_args=(-int) ;;
    *) write_args=(-bool) ;;
    esac
    /bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
      /usr/bin/defaults write "$domain" "$key" "${write_args[@]}" "$value" 2>/dev/null
    ;;
  plist)
    plist_path=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.plistPath')
    key=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.key')
    local value_type
    value_type=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.valueType // "bool"')
    local write_args=(-bool)
    case "$value_type" in
    string) write_args=(-string) ;;
    int) write_args=(-int) ;;
    *) write_args=(-bool) ;;
    esac
    /usr/bin/defaults write "$plist_path" "$key" "${write_args[@]}" "$value" 2>/dev/null
    # Restart the owning daemon so the new preference takes effect (LuLu case).
    local daemon
    daemon=$(echo "$entry_json" | jq -r '.hostEntry.bundleId // empty')
    if [ -n "$daemon" ]; then
      if pgrep -f "$daemon" >/dev/null 2>&1; then
        pkill -f "$daemon" 2>/dev/null || true # check-suppress:suppression_doc: daemon may already be stopping; restart is best-effort.
      fi
    fi
    ;;
  activation-script)
    local script
    script=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.script')
    if [ -n "$script" ]; then
      "$script" "$visible" || warn -l "$(echo "$entry_json" | jq -r '.displayName // "app"')" "activation-script failed"
    fi
    ;;
  *)
    warn -l "$(echo "$entry_json" | jq -r '.displayName // "app"')" "unsupported menuBarIcon kind '$kind'"
    return 1
    ;;
  esac
}

# menu_bar_actual_visible KEY ENTRY_JSON — stdout "true"/"false"/"unknown".
# Reads the native preference and compares to the desired visible value.
menu_bar_actual_visible() {
  local key="$1" entry_json="$2"
  local kind domain key_name plist_path value_type current desired_visible
  kind=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.kind')
  local provisioned
  provisioned=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.provisioned // true')
  if [ "$kind" = "manual" ] || [ "$provisioned" = "false" ]; then
    printf 'manual'
    return 0
  fi
  value_type=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.valueType // "bool"')
  desired_visible=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.iconVisible')
  case "$kind" in
  defaults-key)
    domain=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.domain')
    key_name=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.key')
    _nucleus_resolve_console_user || {
      printf 'unknown'
      return 0
    }
    current=$(/bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" \
      /usr/bin/defaults read "$domain" "$key_name" 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    ;;
  plist)
    plist_path=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.plistPath')
    key_name=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.key')
    current=$(/usr/bin/defaults read "$plist_path" "$key_name" 2>/dev/null) || {
      printf 'unknown'
      return 0
    }
    ;;
  *)
    printf 'unknown'
    return 0
    ;;
  esac
  local desired_value
  desired_value=$(menu_bar_value_for "$desired_visible" "$entry_json")
  if [ "$current" = "$desired_value" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# NixOS per-user dispatch (root activation converges every real user)
# ──────────────────────────────────────────────────────────────────────────────

nixos_real_user_homes() {
  find /home -maxdepth 1 -mindepth 1 -type d 2>/dev/null
}

nixos_dispatch_per_user() {
  local action="$1"
  local overall=0
  local home user
  while IFS= read -r home; do
    [ -d "$home" ] || continue
    user=$(basename "$home")
    if [ "${#app_names[@]}" -gt 0 ]; then
      if ! sudo -u "$user" -H env HOME="$home" NUCLEUS_USERNAME="$user" \
        NUCLEUS_MENU_BAR_AS_USER=1 \
        "$0" "$action" "${app_names[@]}"; then
        overall=1
      fi
    else
      if ! sudo -u "$user" -H env HOME="$home" NUCLEUS_USERNAME="$user" \
        NUCLEUS_MENU_BAR_AS_USER=1 \
        "$0" "$action"; then
        overall=1
      fi
    fi
  done < <(nixos_real_user_homes)
  return "$overall"
}

# ──────────────────────────────────────────────────────────────────────────────
# Per-app state resolution
# ──────────────────────────────────────────────────────────────────────────────

# menu_bar_converge KEY ENTRY_JSON — Apply declared icon state for one app.
# SETs the native preference to the desired state; never disables it.
menu_bar_converge() {
  local key="$1" entry_json="$2"
  local visible
  visible=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.iconVisible')
  menu_bar_native_set "$entry_json" "$visible" || {
    warn -l "$key" "failed to set icon state"
    return 1
  }
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
      local visible
      visible=$(menu_bar_actual_visible "$key" "$entry_json")
      local declared
      declared=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.iconVisible')
      local pair
      pair=$(jq -cn --arg k "$key" --argjson v "$(jq -cn --arg s "$visible" --argjson d "$declared" '{actualVisible:$s, declaredVisible:$d}')" '{key:$k, value:$v}')
      out="${out:+$out
}$pair"
    done < <(echo "$registry" | jq -r 'to_entries[] | [.key, .value.displayName, (.value | tojson)] | @tsv')
    printf '%s\n' "$out" | jq -c -s 'reduce .[] as $i ({}; .[$i.key] = $i.value) | {version: 1, apps: .}'
  else
    printf '%-22s %-10s %-10s %s\n' "ID" "Actual" "Declared" "Name"
    printf '%.0s-' {1..70}
    printf '\n'
    while IFS=$'\t' read -r key display entry_json; do
      local visible declared
      visible=$(menu_bar_actual_visible "$key" "$entry_json")
      declared=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.iconVisible')
      printf '%-22s %-10s %-10s %s\n' "$key" "$visible" "$declared" "$display"
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
    local visible
    visible=$(menu_bar_actual_visible "$key" "$entry_json")
    printf '%-22s %-10s %s\n' "$key" "$visible" "$display"
  done <<<"$entries"
}

do_show() { do_set true; }
do_hide() { do_set false; }

# do_set — Show or hide a named app's icon by setting the native preference.
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
      warn "$app — app not found in registry (or has no menuBarIcon block)"
      overall=1
      continue
    fi
    local overridden
    overridden=$(echo "$entry" | jq --argjson v "$value" '.hostEntry.menuBarIcon.iconVisible = $v')
    if ! menu_bar_converge "$app" "$overridden"; then
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
    if ! menu_bar_converge "$key" "$entry_json"; then
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
    declared=$(echo "$entry_json" | jq -r '.hostEntry.menuBarIcon.iconVisible')
    actual=$(menu_bar_actual_visible "$key" "$entry_json")
    if [ "$actual" = "manual" ]; then
      # Manual entries are declared but not auto-provisioned; no drift check.
      continue
    fi
    if [ "$declared" != "$actual" ]; then
      drift=true
      warn "$key — drift: declared iconVisible=$declared, actual=$actual"
    fi
  done <<<"$entries"
  if $drift; then
    return 1
  fi
  say "all app icons converged to declared state"
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
  list | status | show | hide | apply | verify)
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
  error "missing action (list, status, show, hide, apply, verify)"
  usage >&2
  exit 1
}

# NixOS root activation dispatches per real user; children skip re-dispatch.
if [ "$HOST" = "NixOS" ] && [ -z "${NUCLEUS_MENU_BAR_AS_USER:-}" ]; then
  case "$action" in
  apply | verify)
    nixos_dispatch_per_user "$action"
    exit $?
    ;;
  esac
fi

case "$action" in
list) do_list ;;
status) do_status ;;
show) do_show ;;
hide) do_hide ;;
apply) do_apply ;;
verify) do_verify ;;
*)
  error "unknown action '$action'"
  usage >&2
  exit 1
  ;;
esac
