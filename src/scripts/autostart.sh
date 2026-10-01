#!/usr/bin/env bash
# Uniform CLI over src/modules/apps.json for listing, enabling, disabling, and
# verifying GUI/user app auto-start. This mirrors nucleus-svc but targets
# login/boot auto-start apps rather than background daemons.
#
# Usage: nucleus-autostart <action> [app...] [options]
#
# Policy: an app never manages its own startup. Convergence disables the native
# setting and drives exactly one mechanism we own:
#   macOS   LaunchAgent plists in ~/Library/LaunchAgents/
#   NixOS   an XDG autostart .desktop
#   Windows a Run-key entry or Startup-folder .lnk
#
# Exit non-zero when an app name does not resolve, an action fails, or verify
# finds drift.

set -euo pipefail

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
. "$SCRIPT_DIR/lib/macos-fskit.sh"

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

LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
# WHY console user home: this runs as root under darwin-rebuild switch, where
# $HOME is /var/root, so plists would land in the wrong Library.
if [ "$HOST" = "MacBook" ]; then
  # check-suppress:suppression_doc: /dev/console may not exist in headless/SSH; dscl may fail if user record is missing; both are expected and handled by the empty-check below.
  _console_user_home="$(stat -f%Su /dev/console 2>/dev/null | xargs -I{} dscl . -read "/Users/{}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  if [ -n "$_console_user_home" ]; then
    LAUNCHAGENTS_DIR="$_console_user_home/Library/LaunchAgents"
  fi
fi

macos_launchagent_label() {
  local bundle_id="$1"
  printf 'local.%s' "$bundle_id"
}

macos_launchagent_path() {
  local bundle_id="$1"
  printf '%s/%s.plist' "$LAUNCHAGENTS_DIR" "$(macos_launchagent_label "$bundle_id")"
}

macos_launchagent_exists() {
  local bundle_id="$1"
  [ -f "$(macos_launchagent_path "$bundle_id")" ] && printf 'true' || printf 'false'
}

# Reads CFBundleExecutable from the bundle's Info.plist. Returns the .app path
# as fallback when resolution fails (e.g. missing Info.plist, non-Mach-O bundle).
macos_app_binary_path() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  if [ -f "$info_plist" ]; then
    local binary_name
    # shellcheck disable=SC2086 # reason: PlistBuddy output is a single token (binary name)
    binary_name=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$info_plist" 2>/dev/null || true) # check-suppress:suppression_doc: PlistBuddy fails when Info.plist lacks CFBundleExecutable; fallback to .app path is intentional
    if [ -n "$binary_name" ] && [ -x "$app_path/Contents/MacOS/$binary_name" ]; then
      printf '%s' "$app_path/Contents/MacOS/$binary_name"
      return
    fi
  fi
  printf '%s' "$app_path"
}

macos_launchagent_ensure() {
  local bundle_id="$1" app_path="$2"
  # WHY the binary inside the bundle: launchd cannot execute a .app directory.
  local binary_path
  binary_path="$(macos_app_binary_path "$app_path")"
  local label plist_path
  label="$(macos_launchagent_label "$bundle_id")"
  plist_path="$(macos_launchagent_path "$bundle_id")"
  mkdir -p "$LAUNCHAGENTS_DIR"
  cat >"$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${binary_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <string>${bundle_id}</string>
</dict>
</plist>
PLIST
}

macos_launchagent_remove() {
  local bundle_id="$1"
  rm -f "$(macos_launchagent_path "$bundle_id")"
}

# Delete an app-owned plist whose Program matches the app path, in either plist
# form. Never removes a plist whose program points elsewhere.
macos_remove_app_launchagent() {
  local bundle_id="$1" app_path="$2"
  [ -n "$app_path" ] || return 0
  local plist_path="$LAUNCHAGENTS_DIR/${bundle_id}.plist"
  [ -f "$plist_path" ] || return 0
  local plist_program
  # The `|` address delimiter avoids escaping the `/` in `</key>`: with `/`
  # delimiters BSD sed terminates the address early and fails with
  # "invalid command code", which silently yielded an empty program path.
  plist_program=$(sed -n '\|<key>ProgramArguments</key>|,\|</array>|p' "$plist_path" | sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | head -1)
  # Scalar form: some apps (AltTab) declare <key>Program</key> instead of an
  # argument array; recognising only the array form leaves their agent registered,
  # so the app starts twice.
  if [ -z "$plist_program" ]; then
    plist_program=$(awk '/<key>Program<\/key>/{getline; s=$0; gsub(/.*<string>|<\/string>.*/, "", s); print s; exit}' "$plist_path")
  fi
  if [ -n "$plist_program" ] && { [ "$plist_program" = "$app_path" ] || [[ "$plist_program" == "$app_path/"* ]]; }; then
    rm -f "$plist_path"
  fi
}

# FSKit extensions live in Apple's File System Extension plugin point, which
# systemextensionsctl does not report, and PluginKit rejects a module outside a
# SIP-protected app, so pluginkit reports macFUSE absent while its volumes mount.
# WHY the enabled-module list: it is the signal macOS exposes to a script, and a
# listed module counts as present. An unreadable list answers "false".
macos_fskit_module_registered() {
  local bundle_id="$1"
  case "$(fskit_module_state "$bundle_id")" in
  enabled) printf 'true' ;;
  *) printf 'false' ;;
  esac
}

# Network/cmio/endpoint-security extensions come from systemextensionsctl. TCC
# helpers (e.g. Chrome Remote Desktop Host) appear in neither and stay
# manual-approval-only via the entry's approvalInstructions.
macos_system_extension_present() {
  local bundle_id="$1"
  if command -v systemextensionsctl >/dev/null 2>&1 &&
    systemextensionsctl list 2>/dev/null | grep -q "$bundle_id"; then
    printf 'true'
  else
    macos_fskit_module_registered "$bundle_id"
  fi
}

# WHY the "nucleus-" prefix: it never collides with an app-shipped file such as
# steam.desktop, so our entry stays removable in isolation.
app_desktop_filename() {
  local key="$1"
  printf 'nucleus-%s.desktop' "$(printf '%s' "$key" | tr ' ' '-')"
}

xdg_autostart_dir() {
  printf '%s/autostart' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

xdg_desktop_exists() {
  local name="$1"
  if [ -f "$(xdg_autostart_dir)/$name" ]; then printf 'true'; else printf 'false'; fi
}

xdg_desktop_write() {
  local name="$1" exec_path="$2"
  local dir
  dir=$(xdg_autostart_dir)
  mkdir -p "$dir"
  cat >"$dir/$name" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$name
Exec=$exec_path
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=0
DESKTOP
}

xdg_desktop_remove() {
  local name="$1"
  rm -f "$(xdg_autostart_dir)/$name"
}

# Delete any app-shipped .desktop whose Exec references the app binary, e.g. the
# steam.desktop Steam writes when "Start on login" is toggled.
xdg_native_autostart_remove() {
  local exec_path="$1"
  local dir
  dir=$(xdg_autostart_dir)
  [ -d "$dir" ] || return 0
  local base
  base=$(basename "$exec_path")
  [ -z "$base" ] && return 0
  local f
  for f in "$dir"/*.desktop; do
    [ -f "$f" ] || continue
    if grep -q "^Exec=.*$base" "$f" 2>/dev/null; then
      rm -f "$f"
    fi
  done
}

nixos_real_user_homes() {
  find /home -maxdepth 1 -mindepth 1 -type d 2>/dev/null
}

# Re-exec this script once per real user so each ~/.config/autostart converges.
# NUCLEUS_AUTOSTART_AS_USER stops the child from dispatching again.
nixos_dispatch_per_user() {
  local action="$1"
  local overall=0
  local home user
  while IFS= read -r home; do
    [ -d "$home" ] || continue
    user=$(basename "$home")
    if [ "${#app_names[@]}" -gt 0 ]; then
      if ! sudo -u "$user" -H env HOME="$home" NUCLEUS_USERNAME="$user" \
        NUCLEUS_AUTOSTART_AS_USER=1 \
        "$0" "$action" "${app_names[@]}"; then
        overall=1
      fi
    else
      if ! sudo -u "$user" -H env HOME="$home" NUCLEUS_USERNAME="$user" \
        NUCLEUS_AUTOSTART_AS_USER=1 \
        "$0" "$action"; then
        overall=1
      fi
    fi
  done < <(nixos_real_user_homes)
  return "$overall"
}

app_bundle_id() {
  local entry_json="$1"
  echo "$entry_json" | jq -r '.hostEntry.bundleId // empty'
}

app_declared_display() {
  local entry_json="$1"
  if [ "$(echo "$entry_json" | jq -r '.hostEntry.kind')" = "manual" ]; then
    printf 'manual'
  else
    echo "$entry_json" | jq -r '.hostEntry.autostartEnabled'
  fi
}

app_actual_state() {
  local key="$1" entry_json="$2"
  local kind
  kind=$(echo "$entry_json" | jq -r '.hostEntry.kind')
  case "$kind" in
  macos-launchagent)
    local bundle_id
    bundle_id=$(app_bundle_id "$entry_json")
    if [ -n "$bundle_id" ] && [ "$(macos_launchagent_exists "$bundle_id")" = "true" ]; then
      printf 'enabled'
    else
      printf 'disabled'
    fi
    ;;
  macos-system-extension)
    # WHY unknown off macOS: there is no approval surface to probe, so do not call
    # macOS tooling that cannot exist on this host.
    if [ "$HOST" != "MacBook" ]; then
      printf 'unknown'
      return 0
    fi
    local bundle_id
    bundle_id=$(echo "$entry_json" | jq -r '.hostEntry.bundleId // empty')
    if [ -n "$bundle_id" ] && [ "$(macos_system_extension_present "$bundle_id")" = "true" ]; then
      printf 'enabled'
    else
      printf 'disabled'
    fi
    ;;
  manual)
    printf 'manual'
    ;;
  nixos-xdg-desktop)
    local name
    name=$(app_desktop_filename "$key")
    if [ "$(xdg_desktop_exists "$name")" = "true" ]; then
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

# Every converged kind first neutralizes the app's own native auto-start, so
# only our mechanism remains.
app_converge() {
  local key="$1" entry_json="$2"
  local kind enabled path name
  kind=$(echo "$entry_json" | jq -r '.hostEntry.kind')
  enabled=$(echo "$entry_json" | jq -r '.hostEntry.autostartEnabled // false')
  path=$(echo "$entry_json" | jq -r '.hostEntry.path // empty')

  case "$kind" in
  macos-launchagent)
    local bundle_id
    bundle_id=$(app_bundle_id "$entry_json")
    if [ -z "$bundle_id" ]; then
      warn -l "$key" "missing bundleId — skipping"
      return 1
    fi
    # Remove any app-owned LaunchAgent plist (e.g. AltTab's startAtLogin plist)
    # so the app does not start independently of our mechanism.
    macos_remove_app_launchagent "$bundle_id" "$path" || true # check-suppress:suppression_doc: app-owned plist may be absent; removal is best-effort.
    if [ "$enabled" = "true" ]; then
      macos_launchagent_ensure "$bundle_id" "$path" || die -l "$key" "failed to ensure LaunchAgent plist"
    else
      macos_launchagent_remove "$bundle_id" || true # check-suppress:suppression_doc: plist may already be absent; removal is best-effort.
    fi
    ;;
  macos-system-extension)
    # WHY report rather than fail: approval is manual, so surface
    # approvalInstructions and never pretend we forced the state.
    if [ "$HOST" != "MacBook" ]; then
      error -l "$key" "kind 'macos-system-extension' is macOS-only, but host is '$HOST'"
      return 1
    fi
    local bundle_id approval_instructions
    bundle_id=$(echo "$entry_json" | jq -r '.hostEntry.bundleId // empty')
    approval_instructions=$(echo "$entry_json" | jq -r '.hostEntry.approvalInstructions // empty')
    if [ "$enabled" = "true" ]; then
      if [ -n "$bundle_id" ] && [ "$(macos_fskit_module_registered "$bundle_id")" = "true" ]; then
        # FSKit's enabled-module list is what a script can read; the enablement
        # toggle itself stays manual.
        say -l "$key" "FSKit module registered — it is listed in FSKit's enabled file-system extensions."
      elif [ -n "$bundle_id" ] && [ "$(macos_system_extension_present "$bundle_id")" = "true" ]; then
        say -l "$key" "system extension present (approved)."
      else
        if [ -n "$approval_instructions" ]; then
          warn -l "$key" "$approval_instructions"
        else
          warn -l "$key" "system extension not yet approved — enable it in System Settings → Privacy & Security, then approve the extension."
        fi
      fi
    fi
    ;;
  manual)
    # No programmable mechanism exists here: the state is declared but never
    # converged, so report the manual steps instead of failing apply.
    local manual_instructions
    manual_instructions=$(echo "$entry_json" | jq -r '.hostEntry.approvalInstructions // empty')
    if [ -n "$manual_instructions" ]; then
      warn -l "$key" "$manual_instructions"
    else
      warn -l "$key" "manual entry; not auto-provisioned"
    fi
    ;;
  nixos-xdg-desktop)
    # Neutralize any app-shipped autostart .desktop (e.g. steam.desktop).
    xdg_native_autostart_remove "$path"
    name=$(app_desktop_filename "$key")
    if [ "$enabled" = "true" ]; then
      xdg_desktop_write "$name" "$path" || die -l "$key" "failed to write autostart .desktop"
    else
      xdg_desktop_remove "$name" || true # check-suppress:suppression_doc: our autostart .desktop may already be absent; removal is best-effort.
    fi
    ;;
  *)
    warn -l "$key" "unsupported kind '$kind' on host '$HOST'"
    return 1
    ;;
  esac
}

do_list() {
  local registry
  registry=$(read_registry)
  if [ "$json_output" = true ]; then
    local out=""
    while IFS=$'\t' read -r key display entry_json; do
      local state
      state=$(app_actual_state "$key" "$entry_json")
      local declared
      declared=$(echo "$entry_json" | jq -r '.hostEntry.autostartEnabled')
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
      declared=$(app_declared_display "$entry_json")
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

do_enable() { do_set true; }
do_disable() { do_set false; }

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
    # Override the declared autostartEnabled for this run.
    local overridden
    overridden=$(echo "$entry" | jq --argjson v "$value" '.hostEntry.autostartEnabled = $v')
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
    declared=$(app_declared_display "$entry_json")
    actual=$(app_actual_state "$key" "$entry_json")
    if [ "$actual" = "manual" ]; then
      # Manual entries are declared but not auto-provisioned.
      continue
    fi
    if { [ "$declared" = "true" ] && [ "$actual" != "enabled" ]; } ||
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

# Tab lines key\tdisplay\tentryJson; unknown names become ERROR: rows.
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

# NixOS root activation must converge every real user's autostart dir.
if [ "$HOST" = "NixOS" ] && [ "$(id -u)" -eq 0 ] && [ "${NUCLEUS_AUTOSTART_AS_USER:-}" != "1" ]; then
  case "$action" in
  apply | verify | enable | disable)
    if ! nixos_dispatch_per_user "$action"; then
      exit 1
    fi
    exit 0
    ;;
  esac
fi

case "$action" in
list) do_list ;;
status) do_status ;;
enable) do_enable ;;
disable) do_disable ;;
apply) do_apply ;;
verify) do_verify ;;
esac
