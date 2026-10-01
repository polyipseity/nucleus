#!/usr/bin/env bash
# OS detection, lifecycle ordering, and error boundaries. Heavy logic lives in
# sibling scripts.
set -euo pipefail

# Refuse to run as root: the script escalates with sudo itself when needed.
if [ "$(id -u)" -eq 0 ]; then
  printf '%s\n' "error: this script must not be run as root. Run as a regular user (sudo is used internally when needed)." >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=lib/lib.sh
. "$SCRIPT_DIR/lib/lib.sh"

usage() {
  usage_std 'apply.sh' '[--ai-sync|--no-ai-sync] [--replica-sync|--no-replica-sync] [--store-audit|--no-store-audit] [--target-user=<name>] [--username=<name>] [--vm-sync|--no-vm-sync] [--vm-setup|--no-vm-setup]' \
    'Dispatch the Nix apply command for the current host.'
  exit 0
}

# Subcommand dispatch: health-check and audit-store run standalone; the default
# apply path falls through to the flag parsing and rebuild flow below.
do_health_check() {
  REPO_ROOT="$(derive_repo_root)"

  min_free_bytes=16000000000 # 16 GB — matches nix.custom.conf min-free
  secret_health=true
  log_health=false
  store_audit=false

  if [ "${NUCLEUS_HEALTH_CHECK_STORE_AUDIT:-}" = "1" ]; then
    store_audit=true
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      ;;
    --min-free-bytes)
      if [ "$#" -lt 2 ]; then
        error "--min-free-bytes requires a value"
        exit 1
      fi
      min_free_bytes="$2"
      shift
      ;;
    --secret-health)
      secret_health=true
      ;;
    --no-secret-health)
      secret_health=false
      ;;
    --log-health)
      log_health=true
      require_command jq
      ;;
    --store-audit)
      store_audit=true
      ;;
    --no-store-audit)
      store_audit=false
      ;;
    *)
      error "unsupported argument '$1'"
      exit 1
      ;;
    esac
    shift
  done

  check_disk_space() {
    min_kb=$((min_free_bytes / 1024))
    available_kb=$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print $4 }')

    if [ -z "$available_kb" ] || [ "$available_kb" -lt "$min_kb" ]; then
      error "insufficient disk space at repo filesystem (${available_kb:-0} KiB available, requires ${min_kb} KiB)."
    fi

    return 0
  }

  check_connectivity() {
    if ! curl -fsSI --max-time 10 https://github.com >/dev/null; then
      error "connectivity check failed for https://github.com"
    fi

    if ! curl -fsSI --max-time 10 https://cache.nixos.org >/dev/null; then
      error "connectivity check failed for https://cache.nixos.org"
    fi

    return 0
  }

  check_secret_health() {
    _sch_machine_key="$(nucleus_machine_age_key_path)"
    if [ -f "$_sch_machine_key" ]; then
      SOPS_AGE_KEY_FILE="$_sch_machine_key"
      export SOPS_AGE_KEY_FILE
    fi

    for secret_file in "$REPO_ROOT"/src/secrets/users/*.yml; do
      if [ -f "$secret_file" ] && ! sops -d "$secret_file" >/dev/null; then
        error "unable to decrypt secret file with current identities: $secret_file"
      fi
    done

    return 0
  }

  check_log_health() {
    log_dir="$(nucleus_log_dir)"
    system_log_dir="$(nucleus_system_log_dir)"
    services_json="$REPO_ROOT/src/modules/services.json"
    services_schema_json="$REPO_ROOT/src/modules/services.schema.json"
    _max_size_default=$(jq -r '.definitions.loggingEntry.properties.maxSize.default // 10000000' "$services_schema_json")
    failures=0

    for dir in "$log_dir" "$system_log_dir"; do
      if [ -d "$dir" ]; then
        if [ ! -w "$dir" ]; then
          warn "log dir '$dir' is not writable"
          failures=$((failures + 1))
        fi
      else
        warn "log dir '$dir' does not exist"
        failures=$((failures + 1))
      fi
    done

    while IFS= read -r svc; do
      capture=$(jq -r --arg svc "$svc" '.[$svc].logging.capture // "all"' "$services_json")
      max_size=$(jq -r --arg svc "$svc" --arg def "$_max_size_default" '(.[$svc].logging.maxSize // ($def | tonumber))' "$services_json") # bytes
      # `//` cannot be used here: it also skips `false`, which would make the
      # control-character check warn for a service with sanitization disabled.
      sanitize=$(jq -r --arg svc "$svc" 'if .[$svc].logging.sanitize == null then true else .[$svc].logging.sanitize end' "$services_json")

      if [ "$capture" = "none" ]; then
        continue
      fi

      while IFS= read -r subdir; do
        [ -n "$subdir" ] || continue
        for log_file in "$log_dir/$subdir"/*.log; do
          [ -f "$log_file" ] || continue

          size=$(wc -c <"$log_file")
          threshold=$((max_size * 80 / 100))
          if [ "$size" -gt "$threshold" ]; then
            warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
          fi
          if [ "$size" -gt "$max_size" ]; then
            notice "'$log_file' ($size bytes) exceeds maxSize ($max_size bytes); rotating now"
            rotate_log_file "$log_file" "$max_size" "4" "true"
          fi

          if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
            warn "'$log_file' contains control characters despite sanitize=true"
            failures=$((failures + 1))
          fi
        done
      done <<<"$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.user[]? // empty' "$services_json")"

      while IFS= read -r subdir; do
        [ -n "$subdir" ] || continue
        for log_file in "$system_log_dir/$subdir"/*.log; do
          [ -f "$log_file" ] || continue

          size=$(wc -c <"$log_file")
          threshold=$((max_size * 80 / 100))
          if [ "$size" -gt "$threshold" ]; then
            warn "'$log_file' ($size bytes) exceeds 80% of rotation max ($max_size bytes)"
          fi
          # Trigger immediate rotation when file exceeds maxSize
          if [ "$size" -gt "$max_size" ]; then
            notice "'$log_file' ($size bytes) exceeds maxSize ($max_size bytes); rotating now"
            rotate_log_file "$log_file" "$max_size" "4" "true"
          fi

          if [ "$sanitize" = "true" ] && head -n 5 "$log_file" | tr -d '[:print:][:space:]' | grep -q .; then
            warn "'$log_file' contains control characters despite sanitize=true"
            failures=$((failures + 1))
          fi
        done
      done <<<"$(jq -r --arg svc "$svc" '.[$svc].logging.dirs.system[]? // empty' "$services_json")"
    done <<<"$(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$services_json" | sort)"

    if [ "$failures" -gt 0 ]; then
      error "log health checks failed ($failures issue(s))"
    fi
    return 0
  }

  check_disk_space
  check_connectivity
  if [ "$secret_health" = true ]; then
    check_secret_health
  fi
  if [ "$log_health" = true ]; then
    check_log_health
  fi
  if [ "$store_audit" = true ] && command -v nix >/dev/null 2>&1; then
    require_command jq
    export REPO_ROOT
    # shellcheck source=lib/audit-store.sh
    . "$SCRIPT_DIR/lib/audit-store.sh"
    audit_store_report
  fi

  nuc_done "$@"
}

do_audit_store() {
  REPO_ROOT="$(derive_repo_root)"
  export REPO_ROOT
  # shellcheck source=lib/audit-store.sh
  . "$SCRIPT_DIR/lib/audit-store.sh"
  audit_store_report
  nuc_done "$@"
}

action="${1:-apply}"
case "$action" in
health-check)
  shift
  do_health_check "$@"
  exit $?
  ;;
audit-store)
  shift
  do_audit_store "$@"
  exit $?
  ;;
apply)
  :
  ;;
*)
  action="apply"
  ;;
esac

ai_sync=true
replica_sync=false
vm_sync=true
vm_setup=false
store_audit=false
target_user=""

if [ "${NUCLEUS_HEALTH_CHECK_STORE_AUDIT:-}" = "1" ]; then
  store_audit=true
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
  --ai-sync) ai_sync=true ;;
  --no-ai-sync) ai_sync=false ;;
  --replica-sync) replica_sync=true ;;
  --no-replica-sync) replica_sync=false ;;
  --vm-sync) vm_sync=true ;;
  --no-vm-sync) vm_sync=false ;;
  --vm-setup) vm_setup=true ;;
  --no-vm-setup) vm_setup=false ;;
  --store-audit) store_audit=true ;;
  --no-store-audit) store_audit=false ;;
  --target-user)
    target_user="$2"
    shift
    if [ -z "$target_user" ]; then
      error -l apply "--target-user requires a non-empty value"
      exit 1
    fi
    ;;
  --target-user=*)
    target_user="${1#--target-user=}"
    if [ -z "$target_user" ]; then
      error -l apply "--target-user requires a non-empty value"
      exit 1
    fi
    ;;
  --username)
    NUCLEUS_USERNAME="$2"
    shift
    if [ -z "$NUCLEUS_USERNAME" ]; then
      error -l apply "--username requires a non-empty value"
      exit 1
    fi
    ;;
  -h | --help)
    usage
    ;;
  *)
    error -l apply "unsupported argument '$1'"
    exit 1
    ;;
  esac
  shift
done

REPO_ROOT="$(derive_repo_root)"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

# WHY the live checkout: a store-bundled apply.sh lags behind git pull until the
# next rebuild.
_aar_self="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
_aar_live="$REPO_ROOT/src/scripts/apply.sh"
if [ -f "$_aar_live" ]; then
  _aar_live_resolved="$(CDPATH='' cd -P -- "$(dirname -- "$_aar_live")" && pwd)/$(basename -- "$_aar_live")"
  if [ "$_aar_self" != "$_aar_live_resolved" ]; then
    exec "$_aar_live" "$@"
  fi
fi
unset _aar_self _aar_live _aar_live_resolved

# WHY the profile bin: ssh-to-age and sops must resolve when the script is invoked
# directly, not through `nix run .#apply` (which sets runtimeInputs).
_nix_profile_bin="$HOME/.nix-profile/bin"
case ":$PATH:" in
*":$_nix_profile_bin:"*) ;;
*)
  if [ -d "$_nix_profile_bin" ]; then
    PATH="$PATH:$_nix_profile_bin"
    export PATH
  fi
  ;;
esac
unset _nix_profile_bin

_ash_script_dir="$(cd "$(dirname -- "$0")" && pwd -P)"

run_nix() {
  # WHY min-free 0: the NIX_CONFIG override may not reach the config file before
  # eval reads it, and the CLI flag always wins, so auto-GC stays off for apply.
  NIX_CONFIG="$(merge_nix_config)" NIX_PATH="nixpkgs=flake:nixpkgs" nix --option warn-dirty false --option min-free 0 "$@"
}

run_nix_as_root() {
  # WHY pass the color vars: empty values read as unset to _nuc_color_init, so
  # non-color runs stay byte-identical. Activation scripts never see them, since
  # nix-darwin's activate script runs under `#!/usr/bin/env -i`.
  # Nix eval is hermetic here: the env catalog is a static attrset in the repo
  # tree, so no NUCLEUS_REPO_ROOT forwarding is needed and --impure is dropped.
  NIX_CONFIG_VALUE="$(merge_nix_config)"
  sudo -H env \
    "NIX_CONFIG=$NIX_CONFIG_VALUE" \
    "NIX_PATH=nixpkgs=flake:nixpkgs" \
    "FORCE_COLOR=${FORCE_COLOR:-}" \
    "NO_COLOR=${NO_COLOR:-}" \
    "CLICOLOR_FORCE=${CLICOLOR_FORCE:-}" \
    "TERM=${TERM:-}" \
    nix --option warn-dirty false --option min-free 0 "$@"
}

start_sudo_keepalive() {
  # Prompt for the sudo password once, before build output floods the terminal.
  sudo -v

  # Refresh the sudo timestamp so a long rebuild does not prompt mid-build. The
  # loop dies with the parent and holds no stdio, so a piped run does not hang.
  SCRIPT_PID=$$
  {
    while true; do
      sleep 55
      kill -0 "$SCRIPT_PID" 2>/dev/null || exit
      sudo -n true
    done
  } </dev/null >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!

  # check-suppress:suppression_doc: trap cleanup for sudo keepalive; subprocess may have already exited.
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT INT TERM
}

run_health_check() {
  _rhc_args=()
  if [ "$store_audit" = true ]; then
    _rhc_args+=(--store-audit)
  fi
  run_nix run "$REPO_ROOT/src#apply" health-check "${_rhc_args[@]}"
}

run_pre_build() {
  # WHY hard-error: the activation builds the same derivation and would fail with
  # the same error, so continuing only doubles the failure output.
  _rpb_host="$(resolve_nucleus_host)"
  case "$_rpb_host" in
  MacBook)
    say -l pre-build "pre-building system derivation closure..."
    if ! run_nix build --no-link "$REPO_ROOT/src#darwinConfigurations.MacBook.system"; then
      die -l pre-build "pre-build failed — aborting apply"
    fi
    ;;
  NixOS)
    say -l pre-build "pre-building system derivation closure..."
    if ! run_nix_as_root build --no-link "$REPO_ROOT/src#nixosConfigurations.NixOS.system"; then
      die -l pre-build "pre-build failed — aborting apply"
    fi
    ;;
  *)
    _rpb_user="${target_user:-${NUCLEUS_USERNAME:-$(id -un)}}"
    say -l pre-build "pre-building home-manager derivation closure for $_rpb_user..."
    if ! run_nix build --no-link "$REPO_ROOT/src#homeConfigurations.$_rpb_user.activationPackage"; then
      die -l pre-build "pre-build failed — aborting apply"
    fi
    ;;
  esac
}

run_caddy_local_ca_trust() {
  _rclct_script="$REPO_ROOT/src/scripts/services/caddy-trust.sh"
  if [ ! -f "$_rclct_script" ]; then
    say -l caddy-trust "caddy-trust.sh not found at $_rclct_script; skipping local CA trust"
    return
  fi

  if ! sh "$_rclct_script" "$1"; then
    # WHY: caddy-trust is a convenience feature; apply succeeds without local CA trust.
    warn -l caddy-trust 'delegated trust script exited with an error (continuing without failing apply)'
  fi
}

run_pin_flake_inputs() {
  # Pin flake inputs into a profile so daily GC keeps the *-source paths alive;
  # otherwise every apply re-fetches them from cache.nixos.org.
  _rpfi_profile="/nix/var/nix/profiles/flake-inputs"
  say -l flake-inputs "pinning flake inputs to $_rpfi_profile..."
  if ! run_nix_as_root build --profile "$_rpfi_profile" "$REPO_ROOT/src#flakeInputs"; then
    # WHY: flake-inputs pinning is a GC optimization; inputs re-fetch next apply if unpinned.
    warn -l flake-inputs "flakeInputs build failed (inputs may re-fetch next apply)"
  fi
}

run_post_apply() {
  # Each step is best-effort: failures warn but do not abort apply.
  local _target="${1:-}"
  local _flags=(--repo-root "$REPO_ROOT")
  if [ "$ai_sync" = true ]; then _flags+=(--ai-sync); else _flags+=(--no-ai-sync); fi
  if [ "$replica_sync" = true ]; then _flags+=(--replica-sync); fi
  if [ "$vm_setup" = true ]; then _flags+=(--vm-setup); fi
  if [ "$vm_sync" = false ]; then _flags+=(--no-vm-sync); fi
  _flags+=(--target "$_target")
  sh "$REPO_ROOT/src/scripts/post-apply.sh" "${_flags[@]}"
}

run_terminal_activations() {
  # Commands needing the user's terminal TCC context (macOS Full Disk Access,
  # Accessibility), serialised by the write-terminal-activations HM step into
  # $NUCLEUS_USER_ROOT/terminal-activations.list. Runs after the rebuild so the
  # manifest exists, before post-apply steps that may depend on those changes.
  # Last resort for macOS TCC workarounds only; the full policy lives in
  # src/modules/terminal-activations.nix.
  _rta_manifest="$NUCLEUS_USER_ROOT/terminal-activations.list"
  if [ ! -f "$_rta_manifest" ]; then
    return
  fi

  _rta_count=$(wc -l <"$_rta_manifest")
  if [ "$_rta_count" -eq 0 ]; then
    rm -f "$_rta_manifest"
    return
  fi

  # check-suppress:suppression_doc: grep returns exit code 1 when no lines match; set -e would abort.
  say -l terminal-activations "running $(grep -c '^[^#]' "$_rta_manifest" || true) terminal-context activation(s)..."
  while IFS= read -r _rta_line; do
    case "$_rta_line" in
    '' | '#'*) continue ;;
    esac
    say -l terminal-activations "$_rta_line"
    if ! eval "$_rta_line"; then
      # WHY: terminal-activations are last-resort TCC workarounds; system already rebuilt successfully.
      warn -l terminal-activations "command exited with error (continuing)"
    fi
  done <"$_rta_manifest"
  rm -f "$_rta_manifest"
}

case "$(uname -s)" in
Darwin)
  # nix-darwin manages the system layer and the user Home Manager profile, and
  # darwin-rebuild invokes sudo internally for the system activation.
  if [ -n "$target_user" ]; then
    say -l apply "--target-user is ignored on Darwin system rebuilds (host-level configuration selects the Home Manager user)."
  fi
  start_sudo_keepalive
  "$_ash_script_dir/secrets/generate-ssh-host-key.sh"
  "$_ash_script_dir/secrets/register-host-age-key.sh" --repo-root "$REPO_ROOT"
  run_health_check
  run_pre_build
  # linux-builder saves ~500 MiB RAM when idle; the trap stops it on any exit.
  _lb_started=false
  if command -v nucleus-svc >/dev/null 2>&1; then
    if ! nucleus-svc status linux-builder >/dev/null 2>&1; then
      notice -l linux-builder "starting linux-builder (takes ~30-60s)..."
      if nucleus-svc start linux-builder; then
        _lb_started=true
        # check-suppress:suppression_doc: trap cleanup for linux-builder; stop only if we started it.
        trap 'if [ "$_lb_started" = true ]; then nucleus-svc stop linux-builder >/dev/null 2>&1 || true; fi' EXIT
      else
        warn -l linux-builder "failed to start linux-builder; builds may fail"
      fi
    fi
  fi
  # Activation scripts run under `env -i` and cannot read NUCLEUS_REPO_ROOT, so
  # record the root at the SYSTEM root where derive_repo_root finds it (menu-bar
  # and autostart convergence depend on it).
  sudo -H install -d -m 0755 "/Library/Application Support/nucleus"
  printf '%s\n' "$REPO_ROOT" | sudo -H tee "/Library/Application Support/nucleus/repo-root" >/dev/null
  # WHY -H: root-owned HOME keeps Nix from inheriting a user-owned one.
  run_nix_as_root run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#MacBook"
  # refresh the recorded live repo root in case the checkout moved during activation
  _post_rebuild_repo_root="$(derive_repo_root)"
  printf '%s\n' "$_post_rebuild_repo_root" | sudo -H tee "/Library/Application Support/nucleus/repo-root" >/dev/null
  run_pin_flake_inputs
  run_terminal_activations
  "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
  run_caddy_local_ca_trust sudo
  run_post_apply MacBook
  if [ "$_lb_started" = true ]; then
    # check-suppress:suppression_doc: builder may already be stopped by trap; ignore stop failure.
    nucleus-svc stop linux-builder >/dev/null 2>&1 || true
  fi
  ;;
Linux)
  if [ -f /etc/NIXOS ]; then
    # nixos-rebuild applies the system layer and the embedded home-manager
    # module in one atomic activation.
    if [ -n "$target_user" ]; then
      say -l apply "--target-user is ignored on NixOS system rebuilds (host-level configuration selects the Home Manager user)."
    fi
    start_sudo_keepalive
    "$_ash_script_dir/secrets/generate-ssh-host-key.sh"
    "$_ash_script_dir/secrets/register-host-age-key.sh" --repo-root "$REPO_ROOT"
    run_health_check
    run_pre_build
    # Activation scripts run under `env -i`, so record the live root at the
    # SYSTEM root where derive_repo_root finds it.
    sudo -H install -d -m 0755 "/var/lib/nucleus"
    printf '%s\n' "$REPO_ROOT" | sudo -H tee "/var/lib/nucleus/repo-root" >/dev/null
    # Keep root invocations on root-owned HOME for consistent Nix behavior.
    run_nix_as_root run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#NixOS"
    # refresh in case the checkout moved during activation
    _post_rebuild_repo_root="$(derive_repo_root)"
    printf '%s\n' "$_post_rebuild_repo_root" | sudo -H tee "/var/lib/nucleus/repo-root" >/dev/null
    run_pin_flake_inputs
    run_terminal_activations
    "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
    run_caddy_local_ca_trust sudo
    run_post_apply NixOS
  else
    # Standalone Home Manager (plain Linux or WSL): no system layer and no sudo,
    # so no keepalive. The profile name matches the homeConfigurations key.
    target_username="${target_user:-${NUCLEUS_USERNAME:-$(id -un)}}"
    run_health_check
    run_pre_build
    run_nix run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
    run_pin_flake_inputs
    run_terminal_activations
    "$_ash_script_dir/install-prek-hooks.sh" --repo-root "$REPO_ROOT"
    run_caddy_local_ca_trust user
    run_post_apply NixOS
  fi
  ;;
*)
  error "unsupported OS '$(uname -s)'"
  exit 1
  ;;
esac
