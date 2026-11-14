# shellcheck shell=bash
# The append half of nucleus-logs, inside src/scripts so the store app's script
# tree carries it. Definitions only; callers source lib.sh first for die.

# WHY 4096: a single O_APPEND write(2) of at most one page cannot interleave
# with a concurrent appender, and the kernel never splits a write that fits in a
# page. The limit budgets the trailing newline, so an event is refused once its
# line plus newline reaches this size; it is never truncated, because a
# truncated event is unparseable history.
LOGS_MAX_EVENT_BYTES=4096

# logs_validate_name <log-name>: a log name is a bare filename, so it can never
# escape the log root. A name outside the set is a usage error.
logs_validate_name() {
  case "$1" in
  '' | *[!A-Za-z0-9._-]*) die "invalid log name '$1' (allowed: A-Z a-z 0-9 . _ -)" ;;
  esac
  # WHY: the archive glob is *.[0-9]*.log, so a dot followed by a digit anywhere
  # makes the live file archive-shaped. Such a name writes <name>.log, the
  # rotated archive of the base before that dot, so the two collide outright.
  # That is why the rule is not limited to the last segment.
  case "$1" in
  *.[0-9]*) die "invalid log name '$1': a dot followed by a digit collides with the archive name <base>.<N>.log" ;;
  esac
}

# logs_file_path <dir> <log-name>: print the live file for an already validated
# log name.
logs_file_path() {
  printf '%s/%s.log\n' "$1" "$2"
}

# logs_normalize_event: read one JSON object on stdin and print the canonical
# line, stamping ts when the caller did not supply one.
logs_normalize_event() {
  jq -cS --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    if type == "object" then
      {
        ts: $ts, id: null, kind: null, harness: null, decision: null,
        source: null, filter: null, rule: null, latency_ms: null,
        summary: null, digest: null
      } + .
    else error("event must be a JSON object") end
  '
}

# logs_event_bytes <line>: byte length of one event line without its newline.
logs_event_bytes() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

# logs_check_event_size <bytes>: refuse a line whose write would reach the limit
# once its trailing newline is appended.
logs_check_event_size() {
  if [ "$(($1 + 1))" -ge "$LOGS_MAX_EVENT_BYTES" ]; then
    die "event is $1 bytes; a line plus its newline must stay under $LOGS_MAX_EVENT_BYTES"
  fi
}

# logs_append_event <log-name> <json-line> <log-dir>: append one canonical line.
# This is the writer every caller shares; keep it to a single printf so the whole
# line reaches one write(2) on a file opened O_APPEND.
logs_append_event() {
  local _lae_file=""
  logs_validate_name "$1"
  logs_check_event_size "$(logs_event_bytes "$2")"
  # WHY: an empty root would build a path at the filesystem root, so a log name
  # without a directory is an error rather than a silent relocation.
  [ -n "$3" ] || die "no log directory resolved; cannot append to '$1'"
  mkdir -p "$3"
  _lae_file="$(logs_file_path "$3" "$1")"
  printf '%s\n' "$2" >>"$_lae_file"
}
