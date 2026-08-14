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
  error -l audit-store "REPO_ROOT is not set"
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

_audit_store_closure_groups_jq() {
  jq -r '
    def hsize:
      if . < 1000 then "\(.) B"
      elif . < 1000000 then "\((. / 1000) | floor) kB"
      elif . < 1000000000 then "\((. / 1000000) | floor) MB"
      else "\((. / 1000000000) | floor) GB"
      end;
    def group_prefix($path):
      ($path | capture("/nix/store/[^-]+-(?<name>[^/]+)").name // "other") as $name
      | if ($name | startswith("darwin-system")) then "darwin-system"
        elif ($name | startswith("home-manager-generation")) then "home-manager-generation"
        elif ($name | startswith("nixos-system")) then "nixos-system"
        elif ($name | startswith("home-manager-path")) then "home-manager-path"
        elif ($name | startswith("home-manager")) then "home-manager"
        else $name
        end;
    to_entries
    | group_by(.key | group_prefix(.))
    | map({
        prefix: .[0].key | group_prefix(.),
        total: (map(.value.closureSize) | add)
      })
    | sort_by(.total)
    | reverse
    | .[0:15][]
    | "\(.total | hsize)\t\(.prefix)"
  '
}

_audit_store_gc_root_bucket() {
  case "$1" in
  *direnv* | *flake-inputs*)
    printf '%s\n' direnv
    ;;
  *flake-registry* | */flakes/*)
    printf '%s\n' flake-registry
    ;;
  *profiles/per-user* | *profiles/home-manager* | *nix-profile*)
    printf '%s\n' nix-profile
    ;;
  *home-manager*)
    printf '%s\n' home-manager
    ;;
  *)
    printf '%s\n' other
    ;;
  esac
}

_audit_store_age_cutoff_epoch() {
  _as_age="$1"
  _as_num="${_as_age%[a-zA-Z]*}"
  _as_unit="${_as_age##*[0-9]}"
  case "$(uname -s)" in
  Darwin)
    case "$_as_unit" in
    d) date -j -v-"${_as_num}"d +%s ;;
    w) date -j -v-"${_as_num}"w +%s ;;
    h) date -j -v-"${_as_num}"H +%s ;;
    *) date -j -v-"${_as_num}"d +%s ;;
    esac
    ;;
  *)
    case "$_as_unit" in
    d) date -d "${_as_num} days ago" +%s ;;
    w) date -d "${_as_num} weeks ago" +%s ;;
    h) date -d "${_as_num} hours ago" +%s ;;
    *) date -d "${_as_num} days ago" +%s ;;
    esac
    ;;
  esac
}

_audit_store_capture_system_generations() {
  if command -v darwin-rebuild >/dev/null 2>&1; then
    _audit_store_run_privileged darwin-rebuild --list-generations
    return $?
  fi

  if command -v nix-env >/dev/null 2>&1; then
    for _as_profile in /nix/var/nix/profiles/system /run/current-system; do
      if [ -e "$_as_profile" ]; then
        nix-env -p "$_as_profile" --list-generations
        return 0
      fi
    done
  fi

  return 1
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

  _audit_store_section "nix store closures (grouped by path prefix)"
  if ! _audit_store_closure_groups_jq <"$_as_closures_tmp"; then
    error "failed to group nix path-info JSON output"
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

audit_nix_generation_reclaim_hint() {
  _audit_store_section "generation reclaim hint (intersection retention)"
  _as_keep="${NUCLEUS_GC_GENERATIONS_KEEP:-7}"
  _as_age="${NUCLEUS_GC_EXPIRY:-7d}"

  _as_gen_tmp="$(_audit_store_tmpfile)"
  if ! _audit_store_capture_system_generations >"$_as_gen_tmp" 2>&1; then
    cat "$_as_gen_tmp" >&2
    rm -f "$_as_gen_tmp"
    return 1
  fi

  _as_cutoff="$(_audit_store_age_cutoff_epoch "$_as_age")"
  _as_combined_tmp="$(_audit_store_tmpfile)"
  _as_age_ok_tmp="$(_audit_store_tmpfile)"

  while IFS= read -r _as_line; do
    _as_gen="$(printf '%s' "$_as_line" | awk '{print $1}')"
    _as_date="$(printf '%s' "$_as_line" | awk '{print $2 " " $3}')"
    [ -z "$_as_gen" ] || [ -z "$_as_date" ] && continue
    case "$_as_gen" in
    '' | *[!0-9]*) continue ;;
    esac
    case "$(uname -s)" in
    Darwin) _as_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$_as_date" +%s 2>/dev/null || true)" ;; # check-suppress:suppression_doc: malformed generation timestamps are skipped during reclaim hint parsing
    *) _as_epoch="$(date -d "$_as_date" +%s 2>/dev/null || true)" ;;                             # check-suppress:suppression_doc: malformed generation timestamps are skipped during reclaim hint parsing
    esac
    [ -n "$_as_epoch" ] || continue
    printf '%s\t%s\n' "$_as_gen" "$_as_epoch" >>"$_as_combined_tmp"
  done <"$_as_gen_tmp"

  _as_total="$(wc -l <"$_as_combined_tmp" | tr -d ' ')"
  if [ "$_as_total" -eq 0 ]; then
    say "no parseable system generations found"
    rm -f "$_as_gen_tmp" "$_as_combined_tmp" "$_as_age_ok_tmp"
    return 0
  fi

  sort -k1 -nr "$_as_combined_tmp" | while IFS=$'\t' read -r _as_gen _as_epoch; do
    if [ "$_as_epoch" -ge "$_as_cutoff" ]; then
      printf '%s\n' "$_as_gen" >>"$_as_age_ok_tmp"
    fi
  done

  _as_kept_count=0
  while IFS= read -r _as_gen; do
    _as_kept_count=$((_as_kept_count + 1))
    [ "$_as_kept_count" -ge "$_as_keep" ] && break
  done <"$_as_age_ok_tmp"

  _as_reclaimable=$((_as_total - _as_kept_count))
  say "policy: keep newest $_as_keep AND newer than $_as_age (intersection)"
  say "system generations: $_as_total total, $_as_kept_count kept, $_as_reclaimable reclaimable via nucleus-gc"

  rm -f "$_as_gen_tmp" "$_as_combined_tmp" "$_as_age_ok_tmp"
}

audit_nix_gc_roots() {
  _audit_store_section "gc roots by category"
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
  for _as_bucket in direnv home-manager nix-profile flake-registry other; do
    _as_bucket_tmp="$(_audit_store_tmpfile)"
    while IFS= read -r _as_root_line; do
      [ -z "$_as_root_line" ] && continue
      _as_root_path="${_as_root_line%% -> *}"
      if [ "$(_audit_store_gc_root_bucket "$_as_root_path")" = "$_as_bucket" ]; then
        printf '%s\n' "$_as_root_line" >>"$_as_bucket_tmp"
      fi
    done <"$_as_roots_tmp"

    _as_bucket_count="$(wc -l <"$_as_bucket_tmp" | tr -d ' ')"
    say "$_as_bucket: $_as_bucket_count"
    if [ "$_as_bucket_count" -gt 0 ]; then
      head -n 3 "$_as_bucket_tmp" | while IFS= read -r _as_example; do
        say "  $_as_example"
      done
    fi
    rm -f "$_as_bucket_tmp"
  done
  say "gc root count: $_as_root_count"
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
  audit_nix_generation_reclaim_hint
  audit_nix_gc_roots
  audit_stale_result_symlinks
  audit_linux_builder_store
}
