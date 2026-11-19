# shellcheck shell=bash
# BetterDisplay headless virtual-screen helpers.
#
# Sourceable library: function definitions only, no top-level side effects.
# Callers/tests override BD_BIN, BD_APP, BD_DISPLAY_NAME, BD_PGREP, BD_OPEN, and
# BD_SLEEP; defaults preserve production behavior.
#
# Observed BetterDisplay 5.2.1 CLI contract (2026-11-19):
#   Healthy connected screen: `get -name=<name> -connected`,
#   `get -tagID=<VirtualScreen tag> -connected`, and
#   `get -tagID=<Display tag> -connected` all print `on,on` (rc 0). A virtual
#   screen has two tags (VirtualScreen and Display).
#   Missing screen: `get -name=<name> -connected` prints `Failed.` and exits 1;
#   `get -identifiers -name=<name>` prints `Failed.` and exits 1 (empty/no-match).
#   `set -... -connected=on` exits 0 on an already-connected screen; not proven on
#   a disconnected screen and not relied on.
#
# Status mechanism: bd_reconcile sets BD_RECONCILE_STATUS to one of
# absent|converged|recreated|failed and sets BD_RECONCILE_OBSERVED to the last
# observed connected value (raw, may be empty). It prints nothing by default.

: "${BD_BIN:=/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}"
: "${BD_APP:=/Applications/BetterDisplay.app}"
: "${BD_DISPLAY_NAME:=HeadlessDisplay}"
: "${BD_PGREP:=/usr/bin/pgrep}"
: "${BD_OPEN:=/usr/bin/open}"
: "${BD_SLEEP:=/bin/sleep}"

# Callers read these after bd_reconcile; exported so ShellCheck does not flag
# cross-file use as unused (SC2034).
export BD_RECONCILE_STATUS=""
export BD_RECONCILE_OBSERVED=""

# bd_connected <value>: healthy only when at least one non-empty comma-separated
# field exists and every field (trimmed of whitespace/newlines) is exactly `on`.
# Unknown/mixed/empty shapes are treated as unhealthy (recreate rather than
# trust). Observed healthy: `on,on`. Observed missing: `Failed.`/rc 1/empty.
bd_connected() {
  local value="${1-}" field trimmed any=0
  local IFS=','
  for field in $value; do
    # Trim leading/trailing whitespace and CR/LF.
    trimmed="${field#"${field%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || return 1
    [ "$trimmed" = "on" ] || return 1
    any=1
  done
  [ "$any" -eq 1 ]
}

# bd_create_headless_display: create the managed virtual screen with the pinned
# spec. Returns the BetterDisplay CLI exit code.
bd_create_headless_display() {
  "$BD_BIN" create \
    -type=VirtualScreen \
    -virtualScreenName="$BD_DISPLAY_NAME" \
    -aspectWidth=16 \
    -aspectHeight=10 \
    -multiplierStep=80 \
    -virtualScreenHiDPI=on \
    -connected=on
}

# bd_tag_ids_for_name: print tag IDs for BD_DISPLAY_NAME, one per line, sorted
# unique. Returns 0 even if empty.
bd_tag_ids_for_name() {
  local out
  # check-suppress:suppression_doc: missing screen yields Failed./rc 1; treat as empty.
  out="$("$BD_BIN" get -identifiers -name="$BD_DISPLAY_NAME" 2>/dev/null)" || out=""
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u
}

# bd_connected_state: print the raw connected state for the managed display and
# return 0. On CLI failure or empty output, print nothing.
bd_connected_state() {
  local state rc=0
  state="$("$BD_BIN" get -name="$BD_DISPLAY_NAME" -connected 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$state" ]; then
    return 0
  fi
  printf '%s\n' "$state"
}

# _bd_count_nonempty_lines: print the number of non-empty lines on stdin.
_bd_count_nonempty_lines() {
  /usr/bin/awk 'NF { n++ } END { print n + 0 }'
}

# bd_reconcile: converge to exactly one managed screen that is connected.
# Sets BD_RECONCILE_STATUS (absent|converged|recreated|failed) and
# BD_RECONCILE_OBSERVED (last observed raw connected value, may be empty).
bd_reconcile() {
  local tag_ids tag_count state tag_id
  BD_RECONCILE_STATUS="failed"
  BD_RECONCILE_OBSERVED=""

  if [ ! -f "$BD_BIN" ]; then
    BD_RECONCILE_STATUS="absent"
    return 0
  fi

  if ! "$BD_PGREP" -x "BetterDisplay" >/dev/null 2>&1; then
    # check-suppress:suppression_doc: best-effort launch; reconcile continues.
    "$BD_OPEN" -g -a "$BD_APP" >/dev/null 2>&1 || true
    "$BD_SLEEP" 5
  fi

  tag_ids="$(bd_tag_ids_for_name)"
  tag_count="$(printf '%s\n' "$tag_ids" | _bd_count_nonempty_lines)"
  state="$(bd_connected_state)"
  BD_RECONCILE_OBSERVED="$state"

  if [ "$tag_count" -eq 1 ] && bd_connected "$state"; then
    BD_RECONCILE_STATUS="converged"
    return 0
  fi

  if [ "$tag_count" -gt 0 ]; then
    while IFS= read -r tag_id; do
      [ -n "$tag_id" ] || continue
      if ! "$BD_BIN" discard -tagID="$tag_id" >/dev/null 2>&1; then
        BD_RECONCILE_STATUS="failed"
        return 1
      fi
    done <<EOF
$tag_ids
EOF
  fi

  if ! bd_create_headless_display >/dev/null 2>&1; then
    BD_RECONCILE_STATUS="failed"
    return 1
  fi

  "$BD_SLEEP" 3
  state="$(bd_connected_state)"
  BD_RECONCILE_OBSERVED="$state"
  if ! bd_connected "$state"; then
    BD_RECONCILE_STATUS="failed"
    return 1
  fi

  BD_RECONCILE_STATUS="recreated"
  return 0
}
