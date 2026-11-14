# shellcheck shell=bash
# One audit event for the harness bridge, appended through nucleus-logs.
#
# Sourced by harness-approval, harness-drive, harness-filter, and harness-notify
# after lib.sh and src/scripts/lib/logs.sh: logs_append_event is the only writer,
# so no caller assembles a line or opens a log file itself. The schema's field
# names are the arguments, which is what keeps the four call sites from drifting
# apart.
#
# Every caller passes all ten arguments. An empty string means "absent" and
# reaches the line as null; latency_ms is a whole number of milliseconds.

# harness_audit_now_ms: milliseconds since the epoch.
# WHY EPOCHREALTIME first: it is bash 5 and needs no process, which is what the
# bridge app's interpreter is. A caller running this under macOS's /bin/bash 3.2
# still gets a usable value instead of dying on an unset variable under `set -u`.
harness_audit_now_ms() {
  if [ -n "${EPOCHREALTIME-}" ]; then
    # WHY strip non-digits: EPOCHREALTIME uses the locale's decimal separator, so
    # a comma would survive into arithmetic and break it.
    local _hanm_us="${EPOCHREALTIME//[!0-9]/}"
    printf '%s\n' "$((_hanm_us / 1000))"
    return 0
  fi
  printf '%s\n' "$(($(date +%s) * 1000))"
}

# harness_audit_digest: first 16 hex of the SHA-256 of stdin.
# WHY three tools: macOS ships shasum, NixOS a coreutils sha256sum, and openssl
# stands in where neither is on PATH; every one of them prints the digest in a
# different column, so the parse is per tool.
harness_audit_digest() {
  local _had_hex=""
  if command -v sha256sum >/dev/null 2>&1; then
    _had_hex="$(sha256sum | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    _had_hex="$(shasum -a 256 | cut -d' ' -f1)"
  elif command -v openssl >/dev/null 2>&1; then
    _had_hex="$(openssl dgst -sha256 | awk '{ print $NF }')"
  else
    return 1
  fi
  printf '%s\n' "${_had_hex:0:16}"
}

# harness_audit_log <kind> <harness> <decision> <source> <filter> <rule>
#                   <latency-ms> <summary> <digest> <id>
#
# Appends one event to the `harness` log. Returns non-zero when the event could
# not be built or appended; the caller decides what a failure means, because a
# hook must still print its document.
harness_audit_log() {
  local _hal_kind="$1" _hal_harness="$2" _hal_decision="$3" _hal_source="$4"
  local _hal_filter="$5" _hal_rule="$6" _hal_latency="$7" _hal_summary="$8"
  local _hal_digest="$9" _hal_id="${10}"
  local _hal_dir="" _hal_line=""

  if ! _hal_dir="$(nucleus_log_dir)"; then
    warn "could not resolve the nucleus log directory"
    return 1
  fi
  if [ -z "$_hal_id" ]; then
    _hal_id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  # WHY jq: the summary is free text from a harness, so a hand-built object would
  # break on the first quote or backslash. -S sorts the keys, matching the
  # canonical spelling nucleus-logs writes itself.
  if ! _hal_line="$(jq -cnS \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg id "$_hal_id" \
    --arg kind "$_hal_kind" \
    --arg harness "$_hal_harness" \
    --arg decision "$_hal_decision" \
    --arg source "$_hal_source" \
    --arg filter "$_hal_filter" \
    --arg rule "$_hal_rule" \
    --arg latency "$_hal_latency" \
    --arg summary "$_hal_summary" \
    --arg digest "$_hal_digest" \
    'def absent: if . == "" then null else . end;
     {
       ts: $ts, id: ($id | absent), kind: ($kind | absent),
       harness: ($harness | absent), decision: ($decision | absent),
       source: ($source | absent), filter: ($filter | absent),
       rule: ($rule | absent), latency_ms: ($latency | tonumber? // null),
       summary: ($summary | absent), digest: ($digest | absent)
     }')"; then
    warn "could not encode the harness audit event"
    return 1
  fi

  logs_append_event harness "$_hal_line" "$_hal_dir"
}

# harness_audit_summary: collapse stdin to the one line the summary field holds,
# capped at the schema's 200 characters.
harness_audit_summary() {
  local _has_text=""
  _has_text="$(tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  printf '%s\n' "${_has_text:0:200}"
}
