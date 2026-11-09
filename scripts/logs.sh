#!/usr/bin/env bash
# Append-only JSONL event logs plus rotation and expiry over the managed log
# roots. The single owner of the logging operations: nucleus-gc, log-gc.sh, and
# every writer go through this entry point.
# Subcommands: append, expire, gc, label, rotate, show, stats, tail.
#
# One event per line. Each line is a JSON object with the keys ts, id, kind,
# harness, decision, source, filter, rule, latency_ms, summary, digest; absent
# keys are written as null and keys are sorted, so a line is canonical.

# Resolve symlinks so the script directory works from Nix wrapper symlinks.
# BASH_SOURCE is used rather than $0 so a sourcing caller still resolves this
# file.
_logs_self="${BASH_SOURCE[0]}"
if [ -h "$_logs_self" ]; then
  _target="$(readlink "$_logs_self")"
  case "$_target" in
  /*) _logs_self="$_target" ;;
  *) _logs_self="$(dirname "$_logs_self")/$_target" ;;
  esac
fi
_logs_script_dir="$(CDPATH='' cd -- "$(dirname -- "$_logs_self")" && pwd)"

# WHY the guard: a sourcing caller keeps its own shell options, its SCRIPT_DIR,
# and the libraries it already loaded. Only the executed script turns on strict
# mode and sources lib.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
fi
if ! declare -F nucleus_log_dir >/dev/null; then
  # shellcheck source=../src/scripts/lib/lib.sh
  . "$_logs_script_dir/../src/scripts/lib/lib.sh"
fi
# shellcheck source=../src/scripts/lib/log-expiry.sh
. "$_logs_script_dir/../src/scripts/lib/log-expiry.sh"

# WHY 4096: a single O_APPEND write(2) of at most one page cannot interleave
# with a concurrent appender, and the kernel never splits a write that fits in a
# page. The limit budgets the trailing newline, so an event is refused once its
# line plus newline reaches this size; it is never truncated, because a
# truncated event is unparseable history.
LOGS_MAX_EVENT_BYTES=4096

# Labels are ordinary events appended to the harness log, so a verdict never
# rewrites the line it annotates. Gate decisions live in that log, which is why
# it is the default.
LOGS_LABEL_LOG="harness"

# The verdict vocabulary the gate review reads back.
LOGS_LABEL_VERDICTS="correct false-allow false-deny"

usage() {
  usage_std "$(basename "$0")" "<subcommand> [options]" "Append, inspect, rotate, and expire nucleus JSONL event logs."
  cat <<'EOF'
  append <log-name>                      Append one JSON event object read from stdin.
  expire [--scope <user|system>]         Delete archives older than the expiry.
  gc [--scope <user|system>]             Rotate, then expire.
  label <id> <verdict> [options]         Append a kind=label event (verdict: correct, false-allow, false-deny).
  rotate [--scope <user|system>]         Rotate logs larger than the size limit.
  show <log-name> [options]              Print matching events, oldest first.
  stats [--scope <user|system>]          Count events, bytes, and archives per log.
  tail <log-name> [--scope <user|system>]  Print the last events (default: 10).

  --compress <true|false>  Compress rotated archives (default: services schema).
  --expiry <duration>      Archive retention, e.g. 7d (default: NUCLEUS_LOG_EXPIRY or 7d).
  --harness <name>         show: keep events whose harness matches.
  --json                   Emit one JSON document instead of text.
  --kind <kind>            show: keep events whose kind matches.
  --lines <count>          tail: number of events to print (default: 10).
  --log <name>             label/stats: log name (label default: harness).
  --max-files <count>      Rotated archives to keep (default: services schema).
  --max-size <bytes>       Rotation threshold in bytes (default: services schema).
  --scope <user|system>    Log root to operate on (default: user).
  --since <iso>            show: keep events at or after an ISO-8601 timestamp.
  --note <text>            label: free-text justification stored as the note.
  --dry-run                Report what would change without writing.
EOF
}

# logs_dir_for_scope <user|system>: print the managed log root for a scope. The
# --scope value is validated where it is parsed, so this only maps.
logs_dir_for_scope() {
  case "$1" in
  system) nucleus_system_log_dir ;;
  *) nucleus_log_dir ;;
  esac
}

# logs_validate_name <log-name>: a log name is a bare filename, so it can never
# escape the log root. A name outside the set is a usage error.
logs_validate_name() {
  case "$1" in
  '' | *[!A-Za-z0-9._-]*) die "invalid log name '$1' (allowed: A-Z a-z 0-9 . _ -)" ;;
  esac
  # WHY: a name whose last dot-separated segment is all digits would write
  # <name>.log, which is the rotated archive name of the base before that
  # segment, so a live file and an archive collide outright.
  case "$1" in
  *.*)
    case "${1##*.}" in
    '' | *[!0-9]*) ;;
    *) die "invalid log name '$1': a trailing .<digits> collides with the archive name <base>.<N>.log" ;;
    esac
    ;;
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
  logs_validate_name "$1"
  logs_check_event_size "$(logs_event_bytes "$2")"
  # WHY: an empty root would build a path at the filesystem root, so a log name
  # without a directory is an error rather than a silent relocation.
  [ -n "$3" ] || die "no log directory resolved; cannot append to '$1'"
  mkdir -p "$3"
  _lae_file="$(logs_file_path "$3" "$1")"
  printf '%s\n' "$2" >>"$_lae_file"
}

# logs_append_stdin <log-name> <dry-run true|false> <log-dir>: read exactly one
# event from stdin, reject an oversized one, and append it.
logs_append_stdin() {
  _las_raw=""
  if ! IFS= read -r _las_raw; then
    [ -n "$_las_raw" ] || die "expected one JSON event object on stdin"
  fi
  if IFS= read -r _las_extra; then
    die "expected exactly one event line on stdin"
  fi

  if ! _las_line="$(printf '%s' "$_las_raw" | logs_normalize_event)"; then
    die "event is not a JSON object"
  fi
  _las_bytes="$(logs_event_bytes "$_las_line")"
  logs_check_event_size "$_las_bytes"

  logs_validate_name "$1"

  _las_file="$(logs_file_path "$3" "$1")"
  if [ "$2" = true ]; then
    dry_run "would append $_las_bytes bytes to '$_las_file'"
    printf '%s\n' "$_las_line"
    return 0
  fi
  logs_append_event "$1" "$_las_line" "$3"
}

# logs_schema_default <field> <fallback>: the services.schema.json default for a
# rotation knob, so the app and nucleus-gc cannot disagree about it.
logs_schema_default() {
  if ! _lsd_root="$(derive_repo_root)"; then
    warn "repo root unresolvable; using the built-in $1 default $2"
    printf '%s\n' "$2"
    return 0
  fi
  _lsd_schema="$_lsd_root/src/modules/services.schema.json"
  if [ ! -f "$_lsd_schema" ]; then
    warn "services.schema.json not found; using the built-in $1 default $2"
    printf '%s\n' "$2"
    return 0
  fi
  require_command jq
  _lsd_value="$(jq -r --arg f "$1" '.definitions.loggingEntry.properties | getpath([$f, "default"]) // empty' "$_lsd_schema")"
  if [ -z "$_lsd_value" ]; then
    warn "services.schema.json has no $1 default; using the built-in default $2"
    printf '%s\n' "$2"
  else
    printf '%s\n' "$_lsd_value"
  fi
}

# logs_rotate <dir> <max-size> <max-files> <compress> <dry-run>: the rotation
# itself lives in lib.sh so log-gc.sh and nucleus-gc share one implementation.
logs_rotate() {
  if [ ! -d "$1" ]; then
    return 0
  fi
  if [ "$5" = true ]; then
    dry_run "would rotate logs in '$1' larger than $2 bytes (keeping $3 archives, compress=$4)"
    return 0
  fi
  rotate_logs_in_directory "$1" "$2" "$3" "$4"
}

# logs_expire <dir> <expiry> <dry-run>: archive expiry, same lib.sh owner.
logs_expire() {
  if [ ! -d "$1" ]; then
    return 0
  fi
  if [ "$3" = true ]; then
    dry_run "would expire archives older than $2 in '$1'"
    return 0
  fi
  expire_logs_in_directory "$1" "$2"
}

# logs_event_stream <dir> <log-name>: archives oldest first, then the live file.
# Archives are <base>.<N>.log, gzipped as <base>.<N>.log.gz when compression is on.
logs_event_stream() {
  if [ -d "$1" ]; then
    find "$1" -maxdepth 1 -type f \( -name "$2.[0-9]*.log" -o -name "$2.[0-9]*.log.gz" \) |
      awk -v name="$2" '{ b = $0; sub(/.*\//, "", b); sub(/\.log(\.gz)?$/, "", b); print substr(b, length(name) + 2) "\t" $0 }' |
      sort -rn | cut -f2-
  fi
  if [ -f "$1/$2.log" ]; then
    printf '%s\n' "$1/$2.log"
  fi
}

# logs_read_stream <path>: JSONL from one archive or live file.
logs_read_stream() {
  case "$1" in
  *.gz) gzip -dc "$1" ;;
  *) cat "$1" ;;
  esac
}

# logs_require_value <option> <remaining-arg-count>: fail when a value is absent.
logs_require_value() {
  if [ "$2" -lt 2 ]; then
    error "$1 requires a value"
    exit 1
  fi
}

# logs_render: read JSONL on stdin and print one text line per event.
logs_render() {
  jq -Rr 'fromjson? | [.ts // "-", .kind // "-", .id // "-", .decision // "-", .summary // ""] | @tsv'
}

# logs_show <dir> <log-name> <since> <kind> <harness> <json>: filtered events
# across archives and the live file.
logs_show() {
  _lsh_lines=""
  while IFS= read -r _lsh_path; do
    [ -n "$_lsh_path" ] || continue
    _lsh_lines="${_lsh_lines}$(logs_read_stream "$_lsh_path")
"
  done <<<"$(logs_event_stream "$1" "$2")"

  if ! _lsh_filtered="$(printf '%s' "$_lsh_lines" | jq -cR --arg since "$3" --arg kind "$4" --arg harness "$5" '
      fromjson?
      | select($since == "" or (.ts // "") >= $since)
      | select($kind == "" or (.kind // "") == $kind)
      | select($harness == "" or (.harness // "") == $harness)
    ')"; then
    die "failed to filter events from '$1/$2.log'"
  fi

  if [ "$6" = true ]; then
    printf '%s' "$_lsh_filtered" | jq -s '.'
  else
    printf '%s' "$_lsh_filtered" | logs_render
  fi
}

# logs_tail <dir> <log-name> <count>: the newest events from the live file.
logs_tail() {
  if [ ! -f "$1/$2.log" ]; then
    say "no log '$2' under '$1'"
    return 0
  fi
  tail -n "$3" "$1/$2.log" | logs_render
}

# logs_stats <dir> <log-name-or-empty> <json>: per-log counters.
logs_stats() {
  _lst_rows=""
  for _lst_file in "$1"/*.log; do
    [ -f "$_lst_file" ] || continue
    # WHY the skip: an uncompressed archive is named <base>.<N>.log and matches
    # *.log, but it is rotated history rather than a log of its own.
    case "${_lst_file##*/}" in
    *.[0-9]*.log) continue ;;
    esac
    _lst_name="$(basename -- "$_lst_file" .log)"
    if [ -n "$2" ] && [ "$_lst_name" != "$2" ]; then
      continue
    fi
    _lst_events="$(wc -l <"$_lst_file" | tr -d ' ')"
    _lst_bytes="$(wc -c <"$_lst_file" | tr -d ' ')"
    _lst_archives="$(find "$1" -maxdepth 1 -type f \( -name "$_lst_name.[0-9]*.log" -o -name "$_lst_name.[0-9]*.log.gz" \) | wc -l | tr -d ' ')"
    _lst_last="$(tail -n 1 "$_lst_file" | jq -Rr 'fromjson? | .ts // empty')"
    _lst_rows="${_lst_rows}${_lst_name}	${_lst_events}	${_lst_bytes}	${_lst_archives}	${_lst_last}
"
  done

  if [ "$3" = true ]; then
    printf '%s' "$_lst_rows" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({
          log: .[0],
          events: (.[1] | tonumber),
          bytes: (.[2] | tonumber),
          archives: (.[3] | tonumber),
          last_ts: (if .[4] == "" then null else .[4] end)
        })
    '
    return 0
  fi

  if [ -z "$_lst_rows" ]; then
    say "no logs under '$1'"
    return 0
  fi
  printf 'log\tevents\tbytes\tarchives\tlast_ts\n'
  printf '%s' "$_lst_rows"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _logs_action="${1:-}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$_logs_action" in
  -h | --help | help)
    usage
    exit 0
    ;;
  '')
    error "missing subcommand (append, expire, gc, label, rotate, show, stats, tail)"
    usage >&2
    exit 1
    ;;
  esac

  # Options are parsed per command group, so an option the group does not act on
  # is an error instead of being silently accepted.
  _logs_name=""
  _logs_scope="user"
  _logs_json=false
  _logs_dry=false
  _logs_since=""
  _logs_kind=""
  _logs_harness=""
  _logs_lines=10
  _logs_max_size=""
  _logs_max_files=""
  _logs_compress=""
  _logs_expiry=""
  _logs_label_id=""
  _logs_label_verdict=""
  _logs_label_note=""
  _logs_label_log=""

  case "$_logs_action" in
  append | show | tail)
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --json)
        _logs_json=true
        ;;
      --lines)
        logs_require_value --lines "$#"
        _logs_lines="$2"
        shift
        ;;
      --since)
        logs_require_value --since "$#"
        _logs_since="$2"
        shift
        ;;
      --kind)
        logs_require_value --kind "$#"
        _logs_kind="$2"
        shift
        ;;
      --harness)
        logs_require_value --harness "$#"
        _logs_harness="$2"
        shift
        ;;
      --scope)
        logs_require_value --scope "$#"
        _logs_scope="$2"
        shift
        ;;
      --dry-run)
        _logs_dry=true
        ;;
      -*)
        error "unsupported option '$1' for $_logs_action"
        exit 1
        ;;
      *)
        if [ -n "$_logs_name" ]; then
          error "$_logs_action takes exactly one log name"
          exit 1
        fi
        _logs_name="$1"
        ;;
      esac
      shift
    done
    if [ -z "$_logs_name" ]; then
      error "$_logs_action requires a log name"
      usage >&2
      exit 1
    fi
    ;;
  label)
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --note)
        logs_require_value --note "$#"
        _logs_label_note="$2"
        shift
        ;;
      --log)
        logs_require_value --log "$#"
        _logs_label_log="$2"
        shift
        ;;
      --dry-run)
        _logs_dry=true
        ;;
      -*)
        error "unsupported option '$1' for label"
        exit 1
        ;;
      *)
        if [ -z "$_logs_label_id" ]; then
          _logs_label_id="$1"
        elif [ -z "$_logs_label_verdict" ]; then
          _logs_label_verdict="$1"
        else
          error "label takes an id and a verdict"
          exit 1
        fi
        ;;
      esac
      shift
    done
    if [ -z "$_logs_label_id" ] || [ -z "$_logs_label_verdict" ]; then
      error "label requires an id and a verdict"
      usage >&2
      exit 1
    fi
    ;;
  rotate | expire | gc | stats)
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --scope)
        logs_require_value --scope "$#"
        _logs_scope="$2"
        shift
        ;;
      --max-size)
        logs_require_value --max-size "$#"
        _logs_max_size="$2"
        shift
        ;;
      --max-files)
        logs_require_value --max-files "$#"
        _logs_max_files="$2"
        shift
        ;;
      --compress)
        logs_require_value --compress "$#"
        _logs_compress="$2"
        shift
        ;;
      --expiry)
        logs_require_value --expiry "$#"
        _logs_expiry="$2"
        shift
        ;;
      --log)
        logs_require_value --log "$#"
        _logs_name="$2"
        shift
        ;;
      --json)
        _logs_json=true
        ;;
      --dry-run)
        _logs_dry=true
        ;;
      -*)
        error "unsupported option '$1' for $_logs_action"
        exit 1
        ;;
      *)
        error "$_logs_action takes no positional argument"
        exit 1
        ;;
      esac
      shift
    done
    ;;
  *)
    error "unknown subcommand '$_logs_action' (append, expire, gc, label, rotate, show, stats, tail)"
    usage >&2
    exit 1
    ;;
  esac

  # WHY once, before dispatch: every arm reads the scope, so a typo must fail
  # here instead of silently reading the user tree.
  case "$_logs_scope" in
  user | system) ;;
  *) die "unknown scope '$_logs_scope' (expected user or system)" ;;
  esac

  case "$_logs_action" in
  append)
    _logs_dir="$(logs_dir_for_scope "$_logs_scope")" || die "cannot resolve the nucleus log directory"
    logs_append_stdin "$_logs_name" "$_logs_dry" "$_logs_dir"
    ;;
  label)
    case " $LOGS_LABEL_VERDICTS " in
    *" $_logs_label_verdict "*) ;;
    *) die "invalid verdict '$_logs_label_verdict' (expected: $LOGS_LABEL_VERDICTS)" ;;
    esac
    _logs_label_log="${_logs_label_log:-$LOGS_LABEL_LOG}"
    logs_validate_name "$_logs_label_log"
    _logs_event="$(jq -cn --arg id "$_logs_label_id" --arg verdict "$_logs_label_verdict" \
      --arg note "$_logs_label_note" '{
        kind: "label", id: $id, verdict: $verdict, source: "none",
        note: (if $note == "" then null else $note end)
      }')"
    _logs_line="$(printf '%s' "$_logs_event" | logs_normalize_event)" || die "label: event normalization failed"
    _logs_dir="$(logs_dir_for_scope user)" || die "cannot resolve the nucleus log directory"
    _logs_file="$(logs_file_path "$_logs_dir" "$_logs_label_log")"
    if [ "$_logs_dry" = true ]; then
      dry_run "would append a label event for '$_logs_label_id' to '$_logs_file'"
      printf '%s\n' "$_logs_line"
      exit 0
    fi
    logs_append_event "$_logs_label_log" "$_logs_line" "$_logs_dir"
    ;;
  show)
    logs_validate_name "$_logs_name"
    _logs_dir="$(logs_dir_for_scope "$_logs_scope")" || die "cannot resolve the nucleus log directory"
    logs_show "$_logs_dir" "$_logs_name" "$_logs_since" "$_logs_kind" "$_logs_harness" "$_logs_json"
    ;;
  tail)
    logs_validate_name "$_logs_name"
    _logs_dir="$(logs_dir_for_scope "$_logs_scope")" || die "cannot resolve the nucleus log directory"
    logs_tail "$_logs_dir" "$_logs_name" "$_logs_lines"
    ;;
  stats)
    if [ -n "$_logs_name" ]; then
      logs_validate_name "$_logs_name"
    fi
    _logs_dir="$(logs_dir_for_scope "$_logs_scope")" || die "cannot resolve the nucleus log directory"
    logs_stats "$_logs_dir" "$_logs_name" "$_logs_json"
    ;;
  rotate | expire | gc)
    _logs_dir="$(logs_dir_for_scope "$_logs_scope")" || die "cannot resolve the nucleus log directory"
    _logs_expiry="${_logs_expiry:-$(resolve_log_expiry)}"
    if [ "$_logs_action" != expire ]; then
      _logs_max_size="${_logs_max_size:-$(logs_schema_default maxSize 10000000)}"
      _logs_max_files="${_logs_max_files:-$(logs_schema_default maxFiles 4)}"
      _logs_compress="${_logs_compress:-$(logs_schema_default compress true)}"
      logs_rotate "$_logs_dir" "$_logs_max_size" "$_logs_max_files" "$_logs_compress" "$_logs_dry"
    fi
    if [ "$_logs_action" != rotate ]; then
      logs_expire "$_logs_dir" "$_logs_expiry" "$_logs_dry"
    fi
    ;;
  esac
fi
