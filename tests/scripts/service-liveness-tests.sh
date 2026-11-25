#!/usr/bin/env bash
# Tests for src/scripts/lib/service-liveness.sh
#
# Run with: bash tests/scripts/service-liveness-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
LIVENESS_LIB="$REPO_ROOT/src/scripts/lib/service-liveness.sh"

# Cleanup helper
_cleanup_pids=()
# shellcheck disable=SC2329 # reason: invoked via trap # check-suppress:suppression_doc: trap target
cleanup() {
  local pid
  for pid in "${_cleanup_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

# Start a Python HTTP server that returns given status code
start_http_server_status() {
  local port="$1" status="$2"
  python3 -c "
import http.server
import socketserver
import sys

status_code = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status_code)
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(('127.0.0.1', ${port}), Handler) as httpd:
    httpd.serve_forever()
" "$status" >/dev/null 2>&1 &
  _cleanup_pids+=("$!")
  sleep 0.3
}

# Start a Python HTTP server that returns JSON body
start_http_server_json() {
  local port="$1" body_json="$2"
  python3 -c "
import http.server
import socketserver
import sys
import json

body = json.loads(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(('127.0.0.1', ${port}), Handler) as httpd:
    httpd.serve_forever()
" "$body_json" >/dev/null 2>&1 &
  _cleanup_pids+=("$!")
  sleep 0.3
}

# Find a free port
free_port() {
  python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
"
}

_t_lib_exists() {
  if [ -f "$LIVENESS_LIB" ]; then
    assert_pass "service-liveness.sh exists"
  else
    assert_fail "service-liveness.sh exists" "missing $LIVENESS_LIB"
    finish_tests
  fi
}
_t_lib_exists

# tcp transport-only: closed port
_t_tcp_closed() {
  local port rc out
  port="$(free_port)"
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"tcp\"}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 1 ] && [ "$out" = "dead:connect-failed" ]; then
    assert_pass "tcp transport-only closed port returns dead:connect-failed rc=1"
  else
    assert_fail "tcp transport-only closed port" "rc=$rc out=[$out]"
  fi
}
_t_tcp_closed

# tcp transport-only: listen port
_t_tcp_open() {
  local port rc out
  port="$(free_port)"
  /usr/bin/nc -l 127.0.0.1 "$port" >/dev/null 2>&1 &
  _cleanup_pids+=("$!")
  sleep 0.2
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"tcp\"}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 0 ] && [ "$out" = "live" ]; then
    assert_pass "tcp transport-only open port returns live rc=0"
  else
    assert_fail "tcp transport-only open port" "rc=$rc out=[$out]"
  fi
}
_t_tcp_open

# http 200 live
_t_http_200_live() {
  local port rc out
  port="$(free_port)"
  start_http_server_status "$port" 200
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\",\"health\":{\"path\":\"/\",\"expect\":{\"status\":200}}}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 0 ] && [ "$out" = "live" ]; then
    assert_pass "http 200 with expect status 200 returns live rc=0"
  else
    assert_fail "http 200 live" "rc=$rc out=[$out]"
  fi
}
_t_http_200_live

# http 503 dead
_t_http_503_dead() {
  local port rc out
  port="$(free_port)"
  start_http_server_status "$port" 503
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\",\"health\":{\"path\":\"/\",\"expect\":{\"status\":200}}}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 1 ] && [ "$out" = "dead:status=503" ]; then
    assert_pass "http 503 returns dead:status=503 rc=1"
  else
    assert_fail "http 503 dead" "rc=$rc out=[$out]"
  fi
}
_t_http_503_dead

# statusClass 2xx
_t_status_class_2xx() {
  local port rc out
  port="$(free_port)"
  start_http_server_status "$port" 201
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\",\"health\":{\"path\":\"/\",\"expect\":{\"statusClass\":\"2xx\"}}}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 0 ] && [ "$out" = "live" ]; then
    assert_pass "http 201 with expect statusClass 2xx returns live rc=0"
  else
    assert_fail "statusClass 2xx" "rc=$rc out=[$out]"
  fi
}
_t_status_class_2xx

# bodyJsonSubset match
_t_body_subset_match() {
  local port rc out
  port="$(free_port)"
  start_http_server_json "$port" '{"ok":true,"version":"1.2.3","extra":1}'
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\",\"health\":{\"path\":\"/\",\"expect\":{\"status\":200,\"bodyJsonSubset\":{\"ok\":true}}}}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 0 ] && [ "$out" = "live" ]; then
    assert_pass "bodyJsonSubset match returns live rc=0"
  else
    assert_fail "bodyJsonSubset match" "rc=$rc out=[$out]"
  fi
}
_t_body_subset_match

# bodyJsonSubset mismatch
_t_body_subset_mismatch() {
  local port rc out
  port="$(free_port)"
  start_http_server_json "$port" '{"ok":true,"version":"1.2.3","extra":1}'
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\",\"health\":{\"path\":\"/\",\"expect\":{\"status\":200,\"bodyJsonSubset\":{\"ok\":false}}}}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 1 ] && [ "$out" = "dead:body-mismatch" ]; then
    assert_pass "bodyJsonSubset mismatch returns dead:body-mismatch rc=1"
  else
    assert_fail "bodyJsonSubset mismatch" "rc=$rc out=[$out]"
  fi
}
_t_body_subset_mismatch

# missing health on http => transport-only
_t_http_missing_health_transport_only() {
  local port rc out
  port="$(free_port)"
  start_http_server_status "$port" 200
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '{\"host\":\"127.0.0.1\",\"port\":$port,\"protocol\":\"http\"}'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 0 ] && [ "$out" = "live" ]; then
    assert_pass "missing health on http does transport-only TCP connect returns live rc=0"
  else
    assert_fail "missing health on http transport-only" "rc=$rc out=[$out]"
  fi
}
_t_http_missing_health_transport_only

# timeout/unreachable => unknown (prefer unknown for probe failure). Use a hanging server + short timeout.
_t_http_timeout_unknown() {
  local port rc out
  python3 -c "
import socket
import time

s = socket.socket()
s.bind(('127.0.0.1', 0))
port = s.getsockname()[1]
print(port, flush=True)
s.listen(5)
try:
    while True:
        conn, addr = s.accept()
        time.sleep(30)
        conn.close()
except Exception:
    pass
finally:
    s.close()
" >/tmp/hang_port_test.txt 2>&1 &
  local hpid=$!
  _cleanup_pids+=("$hpid")
  sleep 0.4
  port="$(cat /tmp/hang_port_test.txt 2>/dev/null | tail -1)"
  if [ -z "$port" ]; then
    assert_fail "http timeout gives unknown" "could not get port from hanging server"
    return
  fi
  local ep_json
  ep_json="$(jq -nc --argjson port "$port" '{host:"127.0.0.1",port:$port,protocol:"http",health:{path:"/",timeoutSeconds:1,expect:{status:200}}}')"
  out="$(bash -c "source '$LIVENESS_LIB'; svc_liveness_probe_endpoint '$ep_json'" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -eq 2 ] && [ "$out" = "unknown:timeout" ]; then
    assert_pass "http timeout returns unknown:timeout rc=2"
  else
    assert_fail "http timeout gives unknown" "rc=$rc out=[$out]"
  fi
}
_t_http_timeout_unknown

finish_tests
