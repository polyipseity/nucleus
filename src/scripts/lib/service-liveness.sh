# shellcheck shell=bash
# Liveness probes for nucleus service endpoints. Used by svc tooling and the
# watchdog. Contract: endpoint JSON object (host, port, protocol, optional health).
#
# API:
#   svc_liveness_probe_endpoint <endpoint-json>
#     stdout: short reason (live|dead:...|unknown:...)
#     exit: 0 live, 1 dead/not live, 2 unknown/probe error

[ -n "${_NUCLEUS_SERVICE_LIVENESS_SOURCED-}" ] && return
_NUCLEUS_SERVICE_LIVENESS_SOURCED=1

_SVC_LIVENESS_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SVC_LIVENESS_LIB_DIR/lib.sh"

_svc_liveness_tcp_check() {
  local _sl_host="$1" _sl_port="$2" _sl_timeout="$3"

  # nc is portable on macOS/Linux. It cannot reliably distinguish refused from
  # timeout; treat failure as dead (not listening) as the common case.
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w "$_sl_timeout" "$_sl_host" "$_sl_port" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  # Fallback: bash /dev/tcp with perl alarm for timeout.
  if [ -n "${BASH_VERSION-}" ]; then
    if command -v perl >/dev/null 2>&1; then
      if perl -e 'alarm shift; exec @ARGV' "$_sl_timeout" bash -c "exec 3<>\"/dev/tcp/${_sl_host}/${_sl_port}\"" >/dev/null 2>&1; then
        return 0
      fi
      return 1
    fi
    if (exec 3<>"/dev/tcp/${_sl_host}/${_sl_port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true # check-suppress:suppression_doc: fd may not be open on /dev/tcp fallback path
      return 0
    fi
    return 1
  fi

  return 2
}

svc_liveness_probe_endpoint() {
  local _sle_json="${1:-}"
  local _sle_proto _sle_host _sle_port _sle_host_probe _sle_timeout _sle_has_health
  local _sle_proto_lc _sle_rc _sle_path _sle_url _sle_expect_status _sle_expect_class
  local _sle_has_subset _sle_bodyfile _sle_http_code _sle_curl_status _sle_cls_ok
  local _sle_subset_json _sle_subset_ok
  if [ -z "$_sle_json" ]; then
    printf 'unknown:missing-args\n'
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'unknown:no-jq\n'
    return 2
  fi

  _sle_proto="$(printf '%s' "$_sle_json" | jq -r '.protocol // empty' 2>/dev/null)" || {
    printf 'unknown:invalid-json\n'
    return 2
  }
  _sle_host="$(printf '%s' "$_sle_json" | jq -r '.host // empty' 2>/dev/null)" || _sle_host=""
  _sle_port="$(printf '%s' "$_sle_json" | jq -r '.port // empty' 2>/dev/null)" || _sle_port=""

  if [ -z "$_sle_proto" ] || [ -z "$_sle_host" ] || [ -z "$_sle_port" ] || [ "$_sle_port" = "null" ]; then
    printf 'unknown:missing-fields\n'
    return 2
  fi

  # Normalize host: 0.0.0.0 means listen on all interfaces; probe locally.
  case "$_sle_host" in
  0.0.0.0 | "::") _sle_host_probe="127.0.0.1" ;;
  *) _sle_host_probe="$_sle_host" ;;
  esac

  _sle_timeout="$(printf '%s' "$_sle_json" | jq -r '.health.timeoutSeconds // 5' 2>/dev/null)" || _sle_timeout="5"
  # Validate timeout is a positive integer.
  case "$_sle_timeout" in
  '' | *[!0-9]*) _sle_timeout="5" ;;
  esac
  if [ "$_sle_timeout" -lt 1 ] 2>/dev/null; then
    _sle_timeout="5"
  fi

  _sle_has_health="$(printf '%s' "$_sle_json" | jq -r 'if (.health != null and (.health | type) == "object") then "1" else "0" end' 2>/dev/null)" || _sle_has_health="0"

  # Normalize protocol
  _sle_proto_lc="$(printf '%s' "$_sle_proto" | tr '[:upper:]' '[:lower:]')"
  case "$_sle_proto_lc" in
  tcp)
    _svc_liveness_tcp_check "$_sle_host_probe" "$_sle_port" "$_sle_timeout"
    _sle_rc=$?
    if [ "$_sle_rc" -eq 0 ]; then
      printf 'live\n'
      return 0
    elif [ "$_sle_rc" -eq 1 ]; then
      printf 'dead:connect-failed\n'
      return 1
    else
      printf 'unknown:probe-error\n'
      return 2
    fi
    ;;
  http | https)
    :
    ;;
  *)
    printf 'unknown:unsupported-protocol\n'
    return 2
    ;;
  esac

  if [ "$_sle_proto_lc" = "http" ] || [ "$_sle_proto_lc" = "https" ]; then
    if [ "$_sle_has_health" = "0" ]; then
      # Transport-only: TCP connect to host:port.
      _svc_liveness_tcp_check "$_sle_host_probe" "$_sle_port" "$_sle_timeout"
      _sle_rc=$?
      if [ "$_sle_rc" -eq 0 ]; then
        printf 'live\n'
        return 0
      elif [ "$_sle_rc" -eq 1 ]; then
        printf 'dead:connect-failed\n'
        return 1
      else
        printf 'unknown:probe-error\n'
        return 2
      fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
      printf 'unknown:no-curl\n'
      return 2
    fi

    _sle_path="$(printf '%s' "$_sle_json" | jq -r '.health.path // empty' 2>/dev/null)" || _sle_path=""
    if [ -z "$_sle_path" ]; then
      printf 'unknown:missing-health-path\n'
      return 2
    fi
    _sle_url="${_sle_proto_lc}://${_sle_host_probe}:${_sle_port}${_sle_path}"

    _sle_expect_status="$(printf '%s' "$_sle_json" | jq -r '.health.expect.status // empty' 2>/dev/null)" || _sle_expect_status=""
    _sle_expect_class="$(printf '%s' "$_sle_json" | jq -r '.health.expect.statusClass // empty' 2>/dev/null)" || _sle_expect_class=""
    _sle_has_subset="$(printf '%s' "$_sle_json" | jq -r 'if (.health.expect.bodyJsonSubset != null and (.health.expect.bodyJsonSubset | type) == "object") then "1" else "0" end' 2>/dev/null)" || _sle_has_subset="0"

    _sle_bodyfile=""
    if [ "$_sle_has_subset" = "1" ]; then
      _sle_bodyfile="$(mktemp "${TMPDIR:-/tmp}/svc-liveness-body.XXXXXX")"
    fi

    _sle_http_code=""
    _sle_curl_status=0
    if [ -n "$_sle_bodyfile" ]; then
      _sle_http_code="$(curl -sS --max-time "$_sle_timeout" --connect-timeout "$_sle_timeout" -o "$_sle_bodyfile" -w '%{http_code}' "$_sle_url" 2>/dev/null)"
      _sle_curl_status=$?
    else
      _sle_http_code="$(curl -sS --max-time "$_sle_timeout" --connect-timeout "$_sle_timeout" -o /dev/null -w '%{http_code}' "$_sle_url" 2>/dev/null)"
      _sle_curl_status=$?
    fi
    if [ "$_sle_curl_status" -ne 0 ]; then
      [ -n "$_sle_bodyfile" ] && rm -f "$_sle_bodyfile"
      # curl exit 28 is timeout; prefer unknown for probe failure/timeouts
      if [ "$_sle_curl_status" -eq 28 ]; then
        printf 'unknown:timeout\n'
        return 2
      fi
      # exit 7 is connection failed (often refused) - treat as dead/not live
      if [ "$_sle_curl_status" -eq 7 ]; then
        printf 'dead:connect-failed\n'
        return 1
      fi
      printf 'unknown:transport-failure\n'
      return 2
    fi

    # Validate http code
    case "$_sle_http_code" in
    [0-9][0-9][0-9]) ;;
    *)
      [ -n "$_sle_bodyfile" ] && rm -f "$_sle_bodyfile"
      printf 'unknown:bad-http-code\n'
      return 2
      ;;
    esac

    if [ -n "$_sle_expect_status" ]; then
      if [ "$_sle_http_code" != "$_sle_expect_status" ]; then
        [ -n "$_sle_bodyfile" ] && rm -f "$_sle_bodyfile"
        printf "dead:status=%s\n" "$_sle_http_code"
        return 1
      fi
    elif [ -n "$_sle_expect_class" ]; then
      case "$_sle_expect_class" in
      2xx)
        _sle_cls_ok=0
        [ "${_sle_http_code}" -ge 200 ] 2>/dev/null && [ "${_sle_http_code}" -le 299 ] && _sle_cls_ok=1
        ;;
      3xx)
        _sle_cls_ok=0
        [ "${_sle_http_code}" -ge 300 ] 2>/dev/null && [ "${_sle_http_code}" -le 399 ] && _sle_cls_ok=1
        ;;
      4xx)
        _sle_cls_ok=0
        [ "${_sle_http_code}" -ge 400 ] 2>/dev/null && [ "${_sle_http_code}" -le 499 ] && _sle_cls_ok=1
        ;;
      5xx)
        _sle_cls_ok=0
        [ "${_sle_http_code}" -ge 500 ] 2>/dev/null && [ "${_sle_http_code}" -le 599 ] && _sle_cls_ok=1
        ;;
      *) _sle_cls_ok=0 ;;
      esac
      if [ "${_sle_cls_ok:-0}" -ne 1 ]; then
        [ -n "$_sle_bodyfile" ] && rm -f "$_sle_bodyfile"
        printf "dead:status=%s\n" "$_sle_http_code"
        return 1
      fi
    else
      # Default: expect 2xx
      if [ "${_sle_http_code}" -lt 200 ] 2>/dev/null || [ "${_sle_http_code}" -gt 299 ] 2>/dev/null; then
        [ -n "$_sle_bodyfile" ] && rm -f "$_sle_bodyfile"
        printf "dead:status=%s\n" "$_sle_http_code"
        return 1
      fi
    fi

    if [ "$_sle_has_subset" = "1" ]; then
      _sle_subset_json="$(printf '%s' "$_sle_json" | jq -c '.health.expect.bodyJsonSubset' 2>/dev/null)" || _sle_subset_json=""
      if [ -z "$_sle_subset_json" ] || [ "$_sle_subset_json" = "null" ]; then
        rm -f "$_sle_bodyfile"
        printf 'unknown:invalid-subset\n'
        return 2
      fi
      if ! command -v jq >/dev/null 2>&1; then
        rm -f "$_sle_bodyfile"
        printf 'unknown:no-jq\n'
        return 2
      fi
      # Check: all top-level keys in subset match in response (deep equality of values)
      _sle_subset_ok=0
      if jq -e --argjson sub "$_sle_subset_json" '
        def is_subset($s; $r):
          ($s | type) as $st |
          ($r | type) as $rt |
          if $st != "object" or $rt != "object" then
            $s == $r
          else
            ($s | to_entries | all(. as $e | ($r | has($e.key)) and is_subset($e.value; $r[$e.key])))
          end;
        is_subset($sub; .)
      ' "$_sle_bodyfile" >/dev/null 2>&1; then
        _sle_subset_ok=1
      fi
      rm -f "$_sle_bodyfile"
      if [ "$_sle_subset_ok" -ne 1 ]; then
        printf 'dead:body-mismatch\n'
        return 1
      fi
    fi

    printf 'live\n'
    return 0
  fi

  printf 'unknown:unsupported-protocol\n'
  return 2
}
