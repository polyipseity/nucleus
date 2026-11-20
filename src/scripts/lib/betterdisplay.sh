# shellcheck shell=bash
# BetterDisplay headless virtual-screen helpers.
#
# Sourceable library: function definitions only, no top-level side effects.

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}"
: "${BD_APP:=/Applications/BetterDisplay.app}"
: "${BD_OPEN:=/usr/bin/open}"
: "${BD_DISPLAY_NAME:=HeadlessDisplay}"
# Activation PATH is store-only and does not include pgrep.
: "${BD_PGREP:=/usr/bin/pgrep}"
: "${BD_START_TIMEOUT:=15}"

export BD_PROBE_OBSERVED=""
export BD_PROBE_STATE=""

bd_app_running() {
  "$BD_PGREP" -x "BetterDisplay" >/dev/null 2>&1
}

bd_start_app() {
  # check-suppress:suppression_doc: open failure is surfaced by the bounded poll and the caller.
  "$BD_OPEN" -g -a "$BD_APP" || true
  local i=0
  while [ "$i" -lt "$BD_START_TIMEOUT" ]; do
    if bd_app_running; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  bd_app_running
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

bd_verify() {
  bd_probe
  [ "${BD_PROBE_STATE-}" = "healthy" ] || return 1

  local tag_count
  tag_count="$(bd_tag_ids_for_name | /usr/bin/awk 'NF { n++ } END { print n + 0 }')"
  [ "$tag_count" -eq 1 ] || return 1

  bd_spec_matches
}
