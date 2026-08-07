# shellcheck shell=bash
# Store audit helpers for nucleus hosts.
#
# Source from entry-point scripts after sourcing lib.sh and setting REPO_ROOT.
#
# Privileged sections (generations on Darwin, linux-builder VM launchd) call
# audit_store_acquire_privileges at the start of audit_store_report.
#
# Environment variables:
#   REPO_ROOT  Repository root (required).

[ -n "${REPO_ROOT:-}" ] || {
  printf '%s\n' "audit-store: REPO_ROOT is not set" >&2
  return 1
}

_audit_store_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/nucleus-audit-store.XXXXXX"
}

_audit_store_section() {
  say "=== $1 ==="
}

_audit_store_privileges_required() {
  [ "$(uname -s)" = "Darwin" ]
}

_audit_store_start_sudo_keepalive() {
  sudo -v

  _as_script_pid=$$
  {
    while true; do
      sleep 55
      kill -0 "$_as_script_pid" 2>/dev/null || exit
      sudo -n true
    done
  } </dev/null >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!

  # check-suppress:suppression_doc: trap cleanup for sudo keepalive; subprocess may have already exited.
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT INT TERM
}

# Acquire sudo once on macOS before slow store scans and privileged audits.
# Skips when already root or when a caller (e.g. nucleus-apply) refreshed sudo.
audit_store_acquire_privileges() {
  if ! _audit_store_privileges_required || [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if sudo -n true 2>/dev/null; then
    return 0
  fi

  _audit_store_start_sudo_keepalive
}

_audit_store_run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi

  sudo "$@"
}

_audit_store_linux_builder_ready() {
  _as_lb_label="${LINUX_BUILDER_LAUNCHD_LABEL:-org.nixos.linux-builder}"

  if launchctl print "system/${_as_lb_label}" >/dev/null 2>&1; then
    return 0
  fi

  say "linux-builder launchd job not running; attempting: sudo launchctl kickstart -k system/${_as_lb_label}"

  if ! sudo launchctl kickstart -k "system/${_as_lb_label}"; then
    error "failed to start linux-builder; run 'sudo launchctl kickstart -k system/${_as_lb_label}' then retry"
    return 1
  fi

  return 0
}

_audit_store_top_closures_jq() {
  _as_top_limit="${1:-20}"
  jq -r --argjson top "$_as_top_limit" '
    def hsize:
      if . < 1000 then "\(.) B"
      elif . < 1000000 then "\((. / 1000) | floor) kB"
      elif . < 1000000000 then "\((. / 1000000) | floor) MB"
      else "\((. / 1000000000) | floor) GB"
      end;
    to_entries
    | sort_by(.value.closureSize)
    | reverse
    | .[0:$top][]
    | "\(.value.closureSize | hsize)\t\(.key)"
  '
}

audit_nix_store_closures() {
  _audit_store_section "nix store closures (top 20 by closure size)"
  if ! command -v nix >/dev/null 2>&1; then
    error "nix unavailable; cannot audit store closures"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    error "jq unavailable; cannot audit store closures"
    return 1
  fi

  _as_closures_tmp="$(_audit_store_tmpfile)"
  _as_closures_err="$(_audit_store_tmpfile)"
  if ! nix path-info --json-format 1 --json --all --closure-size >"$_as_closures_tmp" 2>"$_as_closures_err"; then
    error "nix path-info --json --all --closure-size failed; see output below"
    cat "$_as_closures_err" >&2
    rm -f "$_as_closures_tmp" "$_as_closures_err"
    return 1
  fi
  rm -f "$_as_closures_err"

  if ! _audit_store_top_closures_jq <"$_as_closures_tmp"; then
    error "failed to parse nix path-info JSON output"
    rm -f "$_as_closures_tmp"
    return 1
  fi
  rm -f "$_as_closures_tmp"
}

audit_nix_generations() {
  _audit_store_section "system profile generations"

  if command -v darwin-rebuild >/dev/null 2>&1; then
    _as_gen_tmp="$(_audit_store_tmpfile)"
    if ! _audit_store_run_privileged darwin-rebuild --list-generations >"$_as_gen_tmp" 2>&1; then
      cat "$_as_gen_tmp" >&2
      rm -f "$_as_gen_tmp"
      return 1
    fi
    cat "$_as_gen_tmp"
    _as_gen_count="$(wc -l <"$_as_gen_tmp" | tr -d ' ')"
    say "generation count: $_as_gen_count"
    rm -f "$_as_gen_tmp"
    return 0
  fi

  if command -v nix-env >/dev/null 2>&1; then
    for _as_profile in /nix/var/nix/profiles/system /run/current-system; do
      if [ -e "$_as_profile" ]; then
        nix-env -p "$_as_profile" --list-generations
        _as_gen_count="$(nix-env -p "$_as_profile" --list-generations | wc -l | tr -d ' ')"
        say "generation count ($_as_profile): $_as_gen_count"
        return 0
      fi
    done
  fi

  error "no system profile listing command available for generation audit"
  return 1
}

audit_nix_gc_roots() {
  _audit_store_section "gc roots (nix-store --gc --print-roots)"
  if ! command -v nix-store >/dev/null 2>&1; then
    error "nix-store unavailable; cannot audit gc roots"
    return 1
  fi

  _as_roots_tmp="$(_audit_store_tmpfile)"
  if ! nix-store --gc --print-roots >"$_as_roots_tmp" 2>&1; then
    error "nix-store --gc --print-roots failed; see output below"
    cat "$_as_roots_tmp" >&2
    rm -f "$_as_roots_tmp"
    return 1
  fi

  _as_root_count="$(wc -l <"$_as_roots_tmp" | tr -d ' ')"
  head -n 30 "$_as_roots_tmp"
  if [ "$_as_root_count" -gt 30 ]; then
    say "... ($_as_root_count roots total; showing first 30)"
  else
    say "gc root count: $_as_root_count"
  fi
  rm -f "$_as_roots_tmp"
}

audit_stale_result_symlinks() {
  _audit_store_section "stale result symlinks (repo scan)"
  _as_stale_count=0
  while IFS= read -r -d '' _as_path; do
  if [ -L "$_as_path" ]; then
    _as_stale_count=$((_as_stale_count + 1))
    say "$_as_path -> $(readlink "$_as_path")"
  else
    warn "non-symlink at $_as_path — not a Nix build artifact"
  fi
  done < <(
    find "$REPO_ROOT" \
      -path "$REPO_ROOT/.git" -prune -o \
      -path "$REPO_ROOT/.direnv" -prune -o \
      -path "$REPO_ROOT/vendor" -prune -o \
      \( -name result -o -name 'result-*' \) \
      -print0 2>/dev/null || true # check-suppress:suppression_doc: find returns non-zero when -prune skips dirs; || true prevents set -e abort
  )

  if [ "$_as_stale_count" -eq 0 ]; then
    say "no stale result symlinks found"
  else
    say "stale result symlink count: $_as_stale_count"
  fi
}

audit_linux_builder_store() {
  _audit_store_section "linux-builder vm store (MacBook only)"
  if [ "$(uname -s)" != "Darwin" ]; then
    say "skipped (not macOS)"
    return 0
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    error "ssh unavailable; cannot audit linux-builder store"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error "jq unavailable; cannot audit linux-builder store"
    return 1
  fi

  if ! _audit_store_linux_builder_ready; then
    return 1
  fi

  _as_builder_remote='command -v nix >/dev/null 2>&1 || { printf "%s\n" "linux-builder guest: nix not in PATH" >&2; exit 127; }; exec nix --extra-experimental-features nix-command path-info --json-format 1 --json --all --closure-size'

  _as_builder_out="$(_audit_store_tmpfile)"
  _as_builder_err="$(_audit_store_tmpfile)"
  _as_builder_attempt=1
  while [ "$_as_builder_attempt" -le 3 ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 builder@linux-builder "$_as_builder_remote" >"$_as_builder_out" 2>"$_as_builder_err"; then
      if ! _audit_store_top_closures_jq 15 <"$_as_builder_out"; then
        error "failed to parse linux-builder nix path-info JSON output"
        cat "$_as_builder_err" >&2
        rm -f "$_as_builder_out" "$_as_builder_err"
        return 1
      fi
      rm -f "$_as_builder_out" "$_as_builder_err"
      return 0
    fi

    if [ "$_as_builder_attempt" -lt 3 ]; then
      say "linux-builder ssh attempt $_as_builder_attempt failed; retrying in 5s"
      sleep 5
    fi
    _as_builder_attempt=$((_as_builder_attempt + 1))
  done

  error "linux-builder store audit failed after 3 attempts; see output below"
  cat "$_as_builder_err" >&2
  rm -f "$_as_builder_out" "$_as_builder_err"
  error "start the builder with 'sudo launchctl kickstart -k system/org.nixos.linux-builder' then retry"
  return 1
}

audit_store_report() {
  audit_store_acquire_privileges
  audit_nix_store_closures
  audit_nix_generations
  audit_nix_gc_roots
  audit_stale_result_symlinks
  audit_linux_builder_store
}
