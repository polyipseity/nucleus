# shellcheck shell=bash
# BetterDisplay headless virtual-screen helpers.
#
# Sourceable library: function definitions only, no top-level side effects.

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}"
: "${BD_DISPLAY_NAME:=HeadlessDisplay}"
: "${BD_PGREP:=pgrep}"

export BD_PROBE_OBSERVED=""
export BD_PROBE_STATE=""

bd_app_running() {
  "$BD_PGREP" -x "BetterDisplay" >/dev/null 2>&1
}

bd_probe() {
  local rc=0
  BD_PROBE_OBSERVED="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -connected 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$BD_PROBE_OBSERVED" ] || [ "$BD_PROBE_OBSERVED" = "Failed." ]; then
    BD_PROBE_STATE="missing"
  elif [ "$BD_PROBE_OBSERVED" = "on,on" ]; then
    BD_PROBE_STATE="healthy"
  else
    BD_PROBE_STATE="anomaly"
  fi
  return 0
}

bd_tag_ids_for_name() {
  local out
  # check-suppress:suppression_doc: missing screen yields Failed./rc 1; treat as empty.
  out="$("$BD_BIN" get -identifiers -name="$BD_DISPLAY_NAME" 2>/dev/null)" || out=""
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u
}

bd_spec_matches() {
  local hidpi aspect_w aspect_h multiplier resolution

  hidpi="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -virtualScreenHiDPI 2>/dev/null)" || return 1
  [ "$hidpi" = "on" ] || return 1

  aspect_w="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -aspectWidth 2>/dev/null)" || return 1
  [ "$aspect_w" = "16" ] || return 1

  aspect_h="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -aspectHeight 2>/dev/null)" || return 1
  [ "$aspect_h" = "10" ] || return 1

  multiplier="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -multiplierStep 2>/dev/null)" || return 1
  [ "$multiplier" = "80" ] || return 1

  resolution="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -resolution 2>/dev/null)" || return 1
  [ -n "$resolution" ] || return 1

  return 0
}

bd_converge() {
  local tag_id

  while IFS= read -r tag_id; do
    [ -n "$tag_id" ] || continue
    if ! "$BD_BIN" discard -tagID="$tag_id" >/dev/null 2>&1; then
      return 1
    fi
  done < <(bd_tag_ids_for_name)

  "$BD_BIN" create \
    -type=VirtualScreen \
    -virtualScreenName="$BD_DISPLAY_NAME" \
    -aspectWidth=16 \
    -aspectHeight=10 \
    -multiplierStep=80 \
    -virtualScreenHiDPI=on \
    -connected=on >/dev/null 2>&1
}
