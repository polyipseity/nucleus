# shellcheck shell=bash
# Store-space audit helpers for nucleus hosts.
#
# Source from entry-point scripts after sourcing lib.sh and setting REPO_ROOT.
#
# Functions print a human-readable baseline report to stdout. Each section is
# best-effort: missing tools or unreachable services produce warnings, not
# hard failures, so audits can run on partial environments.
#
# Environment variables:
#   REPO_ROOT  Repository root (required).

[ -n "${REPO_ROOT:-}" ] || {
  printf '%s\n' "audit-store-space: REPO_ROOT is not set" >&2
  return 1
}

_audit_store_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/nucleus-audit-store.XXXXXX"
}

_audit_store_section() {
  say "=== $1 ==="
}

audit_nix_store_du() {
  _audit_store_section "nix store du (top 20 closures)"
  if ! command -v nix >/dev/null 2>&1; then
    warn "nix unavailable; skipping store du"
    return 0
  fi

  _as_du_tmp="$(_audit_store_tmpfile)"
  if ! nix store du -S --human-readable >"$_as_du_tmp" 2>&1; then
    warn "nix store du failed; see output below"
    cat "$_as_du_tmp" >&2
    rm -f "$_as_du_tmp"
    return 0
  fi

  head -n 20 "$_as_du_tmp"
  rm -f "$_as_du_tmp"
}

audit_nix_generations() {
  _audit_store_section "system profile generations"

  if command -v darwin-rebuild >/dev/null 2>&1; then
  _as_gen_tmp="$(_audit_store_tmpfile)"
  if darwin-rebuild --list-generations >"$_as_gen_tmp" 2>&1; then
    cat "$_as_gen_tmp"
    _as_gen_count="$(wc -l <"$_as_gen_tmp" | tr -d ' ')"
    say "generation count: $_as_gen_count"
    rm -f "$_as_gen_tmp"
    return 0
  fi
  rm -f "$_as_gen_tmp"
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

  warn "no system profile listing command available; skipping generation audit"
}

audit_nix_gc_roots() {
  _audit_store_section "gc roots (nix-store --print-roots)"
  if ! command -v nix-store >/dev/null 2>&1; then
    warn "nix-store unavailable; skipping gc root audit"
    return 0
  fi

  _as_roots_tmp="$(_audit_store_tmpfile)"
  if ! nix-store --print-roots >"$_as_roots_tmp" 2>&1; then
    warn "nix-store --print-roots failed"
    cat "$_as_roots_tmp" >&2
    rm -f "$_as_roots_tmp"
    return 0
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
    warn "ssh unavailable; skipping linux-builder store audit"
    return 0
  fi

  _as_builder_tmp="$(_audit_store_tmpfile)"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 builder@linux-builder \
    'command -v nix >/dev/null 2>&1 && nix store du -S --human-readable' >"$_as_builder_tmp" 2>&1; then
    warn "linux-builder unreachable or nix store du failed; skipping"
    rm -f "$_as_builder_tmp"
    return 0
  fi

  head -n 15 "$_as_builder_tmp"
  rm -f "$_as_builder_tmp"
}

audit_store_space_report() {
  audit_nix_store_du
  audit_nix_generations
  audit_nix_gc_roots
  audit_stale_result_symlinks
  audit_linux_builder_store
}
