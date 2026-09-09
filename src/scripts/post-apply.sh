#!/usr/bin/env bash
# Post-apply provisioning: jellyfin sync, AI model sync, replica sync,
# VM setup/sync, garbage collection, and manual display.  Called by apply.sh
# after the system rebuild completes.  Each step is best-effort: failures
# warn but do not abort (the system configuration has already been applied).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib/lib.sh
. "$SCRIPT_DIR/lib/lib.sh"

# ── Flag defaults ──────────────────────────────────────────────────
_repo_root="${NUCLEUS_REPO_ROOT:-}"
_ai_sync=true
_replica_sync=false
_vm_setup=false
_vm_sync=true
_target=""

# ── Parse arguments ────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
  --repo-root) _repo_root="$2"; shift 2 ;;
  --no-ai-sync) _ai_sync=false; shift ;;
  --ai-sync) _ai_sync=true; shift ;;
  --replica-sync) _replica_sync=true; shift ;;
  --no-replica-sync) _replica_sync=false; shift ;;
  --vm-setup) _vm_setup=true; shift ;;
  --no-vm-sync) _vm_sync=false; shift ;;
  --target) _target="$2"; shift 2 ;;
  *) shift ;;
  esac
done

if [ -z "$_repo_root" ]; then
  _repo_root="$(derive_repo_root)" || { error "post-apply: could not resolve repo root"; exit 1; }
fi

# ── Per-run apply log ──────────────────────────────────────────────
_apply_log=""
apply_log_init() {
  if [ -z "$_apply_log" ]; then
    _ali_dir="$(nucleus_log_dir)"
    mkdir -p "$_ali_dir"
    _apply_log="$_ali_dir/apply-$(date -u +%Y%m%dT%H%M%SZ).log"
  fi
}

# ── Post-apply steps ───────────────────────────────────────────────

run_jellyfin_sync() {
  _rjs_script="$_repo_root/src/scripts/services/jellyfin-sync.sh"
  if [ ! -f "$_rjs_script" ]; then
    return
  fi
  NUCLEUS_REPO_ROOT="$_repo_root" sh "$_rjs_script"
}

run_ai_sync() {
  if [ "$_ai_sync" = false ]; then
    say -l ai "--no-ai-sync set; skipping post-apply model sync"
    return
  fi

  _ras_script="$_repo_root/scripts/ai.sh"
  if [ ! -f "$_ras_script" ]; then
    say -l ai "scripts/ai.sh not found at $_ras_script; skipping model sync"
    return
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    say -l ai "ollama not found in PATH; skipping post-apply model sync"
    return
  fi

  say -l ai "running post-apply AI model sync..."
  apply_log_init
  if ! sh "$_ras_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l ai "ai.sh sync exited with an error; model sync incomplete (system apply succeeded)"
  fi
}

run_replica_sync() {
  if [ "$_replica_sync" = false ]; then
    say -l replica-sync "skipping post-apply replica sync (default; pass --replica-sync to run now)"
    return
  fi

  _rrb_script="$_repo_root/scripts/cloud.sh"
  if [ ! -f "$_rrb_script" ]; then
    say -l replica-sync "scripts/cloud.sh not found at $_rrb_script; skipping replica sync"
    return
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    say -l replica-sync "rclone not found in PATH; skipping post-apply replica sync"
    return
  fi

  say -l replica-sync "running post-apply replica sync..."
  apply_log_init
  if ! sh "$_rrb_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l replica-sync "cloud.sh sync exited with an error; replica sync incomplete (system apply succeeded)"
  fi
}

run_vm_post_apply() {
  _rvp_script="$_repo_root/scripts/vm.sh"
  if [ ! -f "$_rvp_script" ]; then
    say -l nucleus-vm "scripts/vm.sh not found at $_rvp_script; skipping post-apply VM step"
    return
  fi

  if [ "$_vm_setup" = true ]; then
    say -l nucleus-vm "running post-apply VM provisioning (setup)..."
    apply_log_init
    if ! sh "$_rvp_script" setup --accept-gsi-license 2>&1 | tee -a "$_apply_log"; then
      warn -l nucleus-vm "vm.sh setup exited with an error; VM setup incomplete (system apply succeeded)"
    fi
    return
  fi

  if [ "$_vm_sync" = false ]; then
    say -l nucleus-vm "--no-vm-sync set; skipping post-apply VM config refresh"
    return
  fi

  say -l nucleus-vm "running post-apply VM config refresh (sync)..."
  apply_log_init
  if ! sh "$_rvp_script" sync 2>&1 | tee -a "$_apply_log"; then
    warn -l nucleus-vm "vm.sh sync exited with an error; VM sync incomplete (system apply succeeded)"
  fi
}

run_gc() {
  _rgc_script="$_repo_root/scripts/gc.sh"
  if [ ! -f "$_rgc_script" ]; then
    say -l gc "scripts/gc.sh not found at $_rgc_script; skipping garbage collection"
    return
  fi

  say -l gc "running post-apply garbage collection..."
  apply_log_init
  if ! sh "$_rgc_script" 2>&1 | tee -a "$_apply_log"; then
    warn -l gc "gc.sh exited with an error; GC incomplete (system apply succeeded)"
  fi
}

run_manual_display() {
  if [ -z "$_target" ]; then
    return
  fi
  _rmd_manual="$_repo_root/src/hosts/$_target/MANUAL.md"
  if [ ! -f "$_rmd_manual" ]; then
    return
  fi
  printf '\n'
  cat "$_rmd_manual"
  printf '\n'
}

# ── Main sequence ──────────────────────────────────────────────────
main() {
  run_jellyfin_sync
  run_ai_sync
  run_replica_sync
  run_vm_post_apply
  run_gc
  run_manual_display
}

main
