#!/usr/bin/env bash
# Unified CLI for managing VMs across all hosts (macOS, NixOS, Windows).
# Consolidates build, provision, start, stop, and lifecycle operations
# previously scattered across vm-setup.sh (now vm.sh) and host-specific scripts.
# VMs are defined in src/modules/VMs.json (the canonical manifest).
#
# Commands: setup|list|status|start|stop|upgrade|reset|gc [vm...] [options].
# Guest credentials are resolved from the per-user SOPS secret file referenced
# by users.json vmGuest keys; see resolve_vm_guest_credentials.
#
# Environment variables read: NUCLEUS_VM_SECRET_OWNER, USER, NUCLEUS_REPO_ROOT,
# NUCLEUS_HOST (see lib.sh derive_repo_root / resolve_nucleus_host).
#
# Prerequisites: sops and jq, plus the per-host hypervisor tools (tart, utmctl,
# virsh, qemu). Exits 1 with an error message on missing tools, unknown
# arguments, or manifest lookup failures.

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
# shellcheck source=../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"
# shellcheck source=../src/scripts/lib/size.sh
. "$SCRIPT_DIR/../src/scripts/lib/size.sh"
# shellcheck source=../src/scripts/lib/vm.sh
# shellcheck disable=SC1094 # reason: vm.sh contains inline PowerShell content (backtick-escaped $) that shellcheck cannot parse; pre-existing constraint from the library
. "$SCRIPT_DIR/../src/scripts/lib/vm.sh"

# ---------------------------------------------------------------------------
# Transient helpers — to be migrated into vm.sh as part of the library
# rename pass.  These resolve VM guest credentials from SOPS and compute a
# credential fingerprint for drift detection.
# ---------------------------------------------------------------------------

# current_vm_secret_owner
#   Determines which user owns the SOPS VM secrets: NUCLEUS_VM_SECRET_OWNER
#   (explicit override), then $USER, then `id -un` as last resort. WHY: the
#   owner selects the per-user secret file src/secrets/users-<owner>.yml, so
#   resolution order is override -> session user -> system user. Outputs the
#   owner name on stdout; returns 1 when none can be determined.
current_vm_secret_owner() {
  if [ -n "${NUCLEUS_VM_SECRET_OWNER:-}" ]; then
    printf '%s\n' "$NUCLEUS_VM_SECRET_OWNER"
    return 0
  fi

  if [ -n "${USER:-}" ]; then
    printf '%s\n' "$USER"
    return 0
  fi

  if command -v id >/dev/null 2>&1; then
    id -un
    return 0
  fi

  return 1
}

# resolve_vm_guest_credentials
#   Resolves the VM guest username/password from the per-user SOPS secret file
#   referenced by users.json vmGuest secret-key entries, setting the globals
#   vm_secret_owner, vm_guest_username, vm_guest_password. WHY: credentials
#   stay out of the manifest and are decrypted only at runtime, so the
#   plaintext never touches disk or the flake. Returns 1 with an error message
#   on any failure so callers can degrade gracefully (see do_setup).
resolve_vm_guest_credentials() {
  _rvgc_owner=''
  _rvgc_users_json="$REPO_ROOT/src/modules/users.json"
  _rvgc_secret_file=''

  if _rvgc_owner="$(current_vm_secret_owner)"; then
    :
  else
    _rvgc_owner=''
  fi

  if [ -z "$_rvgc_owner" ]; then
    error "could not determine the per-user VM secret owner (set NUCLEUS_VM_SECRET_OWNER to override)"
    return 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    error "sops not found in PATH; cannot resolve VM guest credentials from SOPS"
    return 1
  fi

  if [ ! -f "$_rvgc_users_json" ]; then
    error "users registry not found: $_rvgc_users_json"
    return 1
  fi

  _rvgc_secret_file="$REPO_ROOT/src/secrets/users-${_rvgc_owner}.yml"
  if [ ! -f "$_rvgc_secret_file" ]; then
    error "per-user VM secret file not found: $_rvgc_secret_file"
    return 1
  fi

  _rvgc_username_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.usernameSecretKey // empty' "$_rvgc_users_json")"
  _rvgc_password_key="$(jq -r --arg owner "$_rvgc_owner" '.[ $owner ].vmGuest.passwordSecretKey // empty' "$_rvgc_users_json")"
  if [ -z "$_rvgc_username_key" ] || [ -z "$_rvgc_password_key" ]; then
    error "vmGuest secret-key references are missing for user $_rvgc_owner in $_rvgc_users_json"
    return 1
  fi

  if ! _rvgc_secret_json="$(sops --decrypt --output-type json "$_rvgc_secret_file")"; then
    error "failed to decrypt per-user VM secret file: $_rvgc_secret_file"
    return 1
  fi

  vm_secret_owner="$_rvgc_owner"
  vm_guest_username="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_username_key" '.[ $key ] // empty')"
  vm_guest_password="$(printf '%s' "$_rvgc_secret_json" | jq -r --arg key "$_rvgc_password_key" '.[ $key ] // empty')"

  if [ -z "$vm_guest_username" ] || [ -z "$vm_guest_password" ]; then
    error "vmGuest secret values are missing in $_rvgc_secret_file for user $_rvgc_owner"
    return 1
  fi

  return 0
}

# resolve_vm_guest_ssh_key
#   Prints the first readable SSH public key found in the standard ~/.ssh
#   locations. WHY: the key is injected into the NixOS guest's authorized_keys
#   during provisioning so key auth works without shipping the private key.
#   Returns 1 when no key exists; do_setup then falls back to password auth.
resolve_vm_guest_ssh_key() {
  local _key_path=''
  for _key_path in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa_sk.pub"; do
    if [ -f "$_key_path" ] && [ -r "$_key_path" ]; then
      cat "$_key_path"
      return 0
    fi
  done
  return 1
}

# vm_guest_credentials_hash
#   Prints a SHA-256 fingerprint of the resolved guest credentials. WHY: the
#   fingerprint lets provisioning detect when SOPS secrets changed and the
#   guest's stored credentials are stale (drift).  Delegates to
#   vm_sha256_input (src/scripts/lib/vm.sh) so all VM fingerprints share one
#   tool chain.
vm_guest_credentials_hash() {
  printf '%s\n%s' "$vm_guest_username" "$vm_guest_password" | vm_sha256_input
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  usage_std "$(basename "$0")" "setup|list|status|start|stop|upgrade|reset|gc [vm...] [options]"
  cat <<'EOF'
  setup                    Build images and provision VMs (full lifecycle).
  list                     List all VMs from manifest with runtime status.
  status [vm...]           Show runtime status of specified VMs (all if omitted).
  start <vm>               Start a VM.
  stop <vm>                Stop a VM.
  upgrade <vm>             Re-download+replace OS image (Android only; error for others).
  reset <vm>               Factory-reset VM user state (Android only; error for others).
  gc                       Remove stale VM artifacts (non-provisioned VMs, disks, markers).
                          Default GC preserves disabled VM entries; pass --gc-disabled
                          to clear them too.

  --dry-run                     Print planned actions without executing (default: off).
  --accept-gsi-license          Accept the GSI license for Android GSI downloads.
  --no-accept-gsi-license       Do not accept the GSI license (default).
  --windows-iso PATH            Path to the Windows 11 ISO.
  --windows-iso-source S        ISO auto-resolution: auto|url|mido (default: auto).
  --windows-iso-retries N       Retry attempts for network downloads (default: 0).
  --headful|--no-headful        Run guest builds with visible GUI (--headful) or
                                headless (--no-headful, default).
  --accelerator A               QEMU accelerator override (hvf|kvm|tcg).
  --gc|--no-gc                  Run GC after setup (default: --no-gc).
  --gc-disabled|--no-gc-disabled  Also clear disabled VM entries during GC
                                (default: --no-gc-disabled).
  --force                       Recreate invalid runtime overlays during setup
                                (default: off; invalid overlays are skipped
                                with a pointer to 'nucleus-vm reset <vm>').
  --vm-dir-override PATH        Override the default ~/virtual machines path.
  --mido-patch-file PATH        Override runtime Mido patch file path.
  --mido-script PATH            Override the Mido script path.
  --json                        Machine-readable JSON output (list, status).
  --repo-root PATH              Override the repository root path.
  -h|--help                     Show usage.
EOF
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# WHY: GSI image downloads require explicit license acceptance, so the flag
# defaults to off rather than silently accepting Google's license terms.
dry_run=false
accept_gsi_license=false
windows_iso=''
windows_iso_source='auto'
windows_iso_retries=0
windows_headless=true
accelerator=''
gc_mode=false
gc_disabled_mode=false
force=false
vm_dir_override=''
NUCLEUS_MIDO_PATCH_FILE=''
NUCLEUS_MIDO_SCRIPT=''
json_output=false
repo_root_override=''
action=''
vm_args=()

# ---------------------------------------------------------------------------
# Global flag parse + subcommand dispatch  (svc.sh pattern)
# WHY: parsing is two-pass (global flags here, subcommand flags in
# filtered_vm_args) so options work in any position relative to the action.
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=true; shift ;;
    --accept-gsi-license) accept_gsi_license=true; shift ;;
    --no-accept-gsi-license) accept_gsi_license=false; shift ;;
    --windows-iso) windows_iso="$2"; shift 2 ;;
    --windows-iso-source) windows_iso_source="$2"; shift 2 ;;
    --windows-iso-retries) windows_iso_retries="$2"; shift 2 ;;
    --headful) windows_headless=false; shift ;;
    --no-headful) windows_headless=true; shift ;;
    --accelerator) accelerator="$2"; shift 2 ;;
    --gc) gc_mode=true; shift ;;
    --no-gc) gc_mode=false; shift ;;
    --gc-disabled) gc_disabled_mode=true; shift ;;
    --no-gc-disabled) gc_disabled_mode=false; shift ;;
    --force) force=true; shift ;;
    --vm-dir-override) vm_dir_override="$2"; shift 2 ;;
    --mido-patch-file) NUCLEUS_MIDO_PATCH_FILE="$2"; shift 2 ;;
    --mido-script) NUCLEUS_MIDO_SCRIPT="$2"; shift 2 ;;
    --json) json_output=true; shift ;;
    --repo-root) repo_root_override="$2"; shift 2 ;;
    setup|list|status|start|stop|upgrade|reset|gc)
      action="$1"; shift
      vm_args=("$@")
      break
      ;;
    *) error "unsupported argument '$1'" ; usage >&2 ; exit 1 ;;
  esac
done

# Filter subcommand flags from vm_args (can appear before or after subcommand,
# same pattern as svc.sh --json/--verbose filtering).
# WHY: folding post-subcommand flags into the same option set makes flag
# order irrelevant; unknown flags only warn so subcommand flags can pass.
filtered_vm_args=()
for arg in "${vm_args[@]}"; do
  case "$arg" in
    --json) json_output=true ;;
    --dry-run) dry_run=true ;;
    --gc) gc_mode=true ;;
    --no-gc) gc_mode=false ;;
    --gc-disabled) gc_disabled_mode=true ;;
    --no-gc-disabled) gc_disabled_mode=false ;;
    --force) force=true ;;
    --accept-gsi-license) accept_gsi_license=true ;;
    --no-accept-gsi-license) accept_gsi_license=false ;;
    --headful) windows_headless=false ;;
    --no-headful) windows_headless=true ;;
    --) break ;;
    -*) warn "ignoring unknown flag after subcommand: $arg" ;;
    *) filtered_vm_args+=("$arg") ;;
  esac
done

[ -z "$action" ] && { error "missing action (setup, list, status, start, stop, upgrade, reset, gc)" ; usage >&2 ; exit 1; }

# Validate scalars
# WHY: validating before dispatch fails fast with a precise message instead
# of surfacing the same error deep inside a subcommand build.
case "$windows_iso_source" in
  auto|url|mido|'') ;;
  *)
    error "invalid --windows-iso-source value: $windows_iso_source; expected one of: auto, url, mido"
    ;;
esac

case "$windows_iso_retries" in
  ''|*[!0-9]*)
    error "invalid --windows-iso-retries value: $windows_iso_retries; expected a non-negative integer"
    ;;
esac

# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------

# resolve_manifest
#   Locates the VM manifest and derives the VM/image/template directories
#   from it. WHY: paths derive from REPO_ROOT rather than being hard-coded,
#   so --repo-root overrides and Nix store layouts keep working. Exits 1
#   when the manifest is missing.
resolve_manifest() {
  MANIFEST="$REPO_ROOT/src/modules/VMs.json"
  VMS_DIR="$REPO_ROOT/src/vms"
  TEMPLATES_DIR="$VMS_DIR/templates"

  if [ ! -f "$MANIFEST" ]; then
    error "manifest not found at $MANIFEST"
    exit 1
  fi
}

# resolve_target_vm ID — look up a VM by id in the manifest, print
# "type<tab>index" or exit with error.
# WHY: the index is the manifest position used to address the VM in build
# commands, not a runtime identifier.
resolve_target_vm() {
  local _rtv_name="$1"
  _rtv_type="$(jq -r --arg name "$_rtv_name" '.VMs[] | select(.id == $name) | .type // empty' "$MANIFEST")"
  _rtv_index="$(jq --arg name "$_rtv_name" '[.VMs[] | .id] | index($name)' "$MANIFEST")"
  if [ -z "$_rtv_type" ] || [ "$_rtv_index" = "null" ]; then
    error "VM '$_rtv_name' not found in manifest"
    return 1
  fi
  printf '%s\t%s\n' "$_rtv_type" "$_rtv_index"
}

# ---------------------------------------------------------------------------
# Subcommand implementations
# ---------------------------------------------------------------------------

# do_setup
#   Full lifecycle: resolve credentials, init the runtime, build images, run
#   host-specific provisioners, then optionally GC. WHY: credential failure
#   degrades to no-drift-detection instead of aborting, so a missing secret
#   file cannot block provisioning of VMs that need no guest access.
do_setup() {
  require_command jq

  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  export NUCLEUS_HOST

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"
  IMAGES_DIR="$VM_DIR/images"

  # Auto-detect QEMU accelerator if not specified
  if [ -z "$accelerator" ]; then
    case "$(uname -s)" in
      Darwin)
        if [ "$(uname -m)" = "arm64" ]; then
          # WHY: Hypervisor.framework on Apple Silicon only accelerates AArch64
          # guests; qemu-system-x86_64 -accel hvf fails instantly.
          accelerator='tcg'
        else
          accelerator='hvf'
        fi
        ;;
      # WHY: KVM is the only practical accelerator for Linux guests; tcg is
      # the portable fallback for hosts without hardware virtualization.
      Linux)  accelerator='kvm' ;;
      *)      accelerator='tcg' ;;
    esac
  fi

  # Resolve guest credentials
  if ! resolve_vm_guest_credentials; then
    say "guest credential resolution failed; proceeding without drift detection"
    vm_secret_owner=''
    vm_guest_username=''
    vm_guest_password=''
    vm_guest_credentials_fingerprint=''
  else
    vm_guest_credentials_fingerprint="$(vm_guest_credentials_hash)"
    export NUCLEUS_VM_GUEST_USERNAME="$vm_guest_username"
    export NUCLEUS_VM_GUEST_PASSWORD="$vm_guest_password"

    # Export SSH public key for NixOS guest provisioning (guest.nix uses it for authorized_keys).
    vm_guest_ssh_public_key="$(resolve_vm_guest_ssh_key)" || true  # check-suppress:suppression_doc: resolve_vm_guest_ssh_key may fail when no guest SSH key exists; an empty value skips key provisioning
    if [ -n "$vm_guest_ssh_public_key" ]; then
      export NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY="$vm_guest_ssh_public_key"
    else
      warn "no SSH public key found; NixOS guest will use password auth only"
    fi
  fi

  vm_init "$REPO_ROOT" "$VM_DIR" "$IMAGES_DIR" "$TEMPLATES_DIR" "$dry_run" \
    "$windows_iso" "$windows_iso_source" "$windows_iso_retries" \
    "$windows_headless" "$accelerator" "$vm_secret_owner" "$vm_guest_username" \
    "$vm_guest_password" "$vm_guest_credentials_fingerprint" \
    "$NUCLEUS_MIDO_PATCH_FILE" "$NUCLEUS_MIDO_SCRIPT" \
    "$accept_gsi_license" "false" "false" \
    "$VMS_DIR" "$MANIFEST" "$NUCLEUS_HOST" "$gc_disabled_mode" "$force"

  mkdir -p "$VM_DIR" "$IMAGES_DIR" "$VM_DIR/scripts"
  write_vm_directory_readme

  # Write self-describing descriptors for EVERY manifest guest (enabled or
  # disabled, host-matched or not) so scripts/ and unpack can serve disabled
  # VMs without a live manifest.
  vm_write_descriptors

  # Prune stale helper scripts from previous runs, then write the complete
  # all-guests set (start/stop + pack/unpack, both .sh and .ps1 variants).
  # WHY: leftover scripts from renamed or removed VMs would otherwise be
  # picked up by do_start/do_stop; the all-guests pass regenerates every
  # current manifest guest regardless of enable/host-match state.
  for f in "$VM_DIR/scripts"/*.sh "$VM_DIR/scripts"/*.ps1; do
    [ -f "$f" ] || continue
    rm -f "$f"
  done
  vm_write_all_guest_scripts

  # Darwin-specific environment setup
  if [ "$(uname -s)" = "Darwin" ]; then
    ensure_tart_vm_dir
    ensure_utm_default_vm_location
  fi

  vm_build_images

  # Host-specific provisioners
  case "$(uname -s)" in
    Darwin)
      vm_setup_tart_vms
      vm_setup_utm_vms
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        vm_setup_libvirt_vms
      else
        say "unsupported Linux host"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      vm_setup_windows_qemu_vms
      ;;
  esac

  if [ "$gc_mode" = true ]; then
    vm_gc_vms
  fi

  nuc_done
}

# Query hypervisors for currently running VM names.
# Outputs one name per line; empty output means nothing is running.
# WHY: state is read from the live hypervisor rather than the manifest, so
# list/status reflect reality (e.g. VMs started outside nucleus).
vm_get_running_names() {
  case "$(uname -s)" in
    Darwin)
      tart list 2>/dev/null | awk 'NR>1{print $2}'
      utmctl list 2>/dev/null | awk 'NR>1{print $3}'
      ;;
    Linux)
      virsh list --name 2>/dev/null
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Runtime detection on Windows is handled by PowerShell.
      return 0
      ;;
  esac
}

# Annotate a VM name with its running state.
# Returns "running", "stopped", or "unknown".
_vm_state() {
  _vs_name="$1"
  _vs_running_set="$2"
  if echo "$_vs_running_set" | grep -qxF "$_vs_name"; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

# do_list
#   Lists enabled VMs scoped to the current host, annotated with live
#   running/stopped state. WHY: the jq host filter mirrors the manifest's
#   hosts field, so each machine only sees the VMs it can actually manage.
do_list() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  local running_names
  running_names="$(vm_get_running_names)" || true  # check-suppress:suppression_doc: vm_get_running_names may exit non-zero when no VMs match; the empty list is handled downstream

  if $json_output; then
    # Annotate each VM with its state.
    jq -c --arg host "$NUCLEUS_HOST" '
      [.VMs[] | select(.enabled == true) | select(.hosts | contains([$host]))]
    ' "$MANIFEST" | jq -c --arg running "$running_names" '
      [.[] | .state = (if $running| split("\n") | index(.id) then "running" else "stopped" end)]
    '
  else
    printf '%-20s %-12s %-10s %-8s %s\n' "NAME" "TYPE" "ENABLED" "STATE" "HOSTS"
    jq -r --arg host "$NUCLEUS_HOST" '
      .VMs[] | select(.enabled == true) | select(.hosts | contains([$host])) |
      [.name, .type, (.enabled | tostring), (.hosts | join(",")), .id] |
      @tsv
    ' "$MANIFEST" | while IFS=$'\t' read -r name type enabled hosts id; do
      local state
      state="$(_vm_state "$id" "$running_names")"
      printf '%-20s %-12s %-10s %-8s %s\n' "$name" "$type" "$enabled" "$state" "$hosts"
    done
  fi
}

# do_status
#   Shows CPUs/RAM and live state for enabled VMs on this host, optionally
#   filtered to names given after the subcommand. WHY: the suffixed ram string
#   is parsed to bytes and displayed as whole decimal GB so the table stays
#   readable.
do_status() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  local running_names
  running_names="$(vm_get_running_names)" || true  # check-suppress:suppression_doc: vm_get_running_names may exit non-zero when no VMs match; the empty list is handled downstream

  # Build base filter: enabled VMs matching the current host.
  # Names are passed via --argjson when filtering specific VMs.
  local base_filter
  # shellcheck disable=SC2016 # reason: $host is a jq variable, not shell expansion
  base_filter='[.VMs[] | select(.enabled == true) | select(.hosts | contains([$host]))]'

  local names_json=''
  if [ "${#filtered_vm_args[@]}" -gt 0 ]; then
    local names_list=''
    for name in "${filtered_vm_args[@]}"; do
      names_list+="\"$name\","
    done
    names_json="[${names_list%,}]"
    # Append id filter using single-quote concatenation to avoid SC2140.
    # shellcheck disable=SC2016 # reason: $n and $names are jq variables, not shell expansion
    base_filter="${base_filter%]}"' | select(.id as $n | $names | index($n))]'
  fi

  if $json_output; then
    if [ -n "$names_json" ]; then
      jq -c --arg host "$NUCLEUS_HOST" --argjson names "$names_json" "$base_filter" "$MANIFEST" | \
        jq -c --arg running "$running_names" '
          [.[] | .state = (if $running| split("\n") | index(.id) then "running" else "stopped" end)]
        '
    else
      jq -c --arg host "$NUCLEUS_HOST" "$base_filter" "$MANIFEST" | \
        jq -c --arg running "$running_names" '
          [.[] | .state = (if $running| split("\n") | index(.id) then "running" else "stopped" end)]
        '
    fi
  else
    printf '%-20s %-12s %-10s %-8s %-8s %-8s %-10s\n' "NAME" "TYPE" "ENABLED" "STATE" "HOSTS" "CPUS" "RAM"

    # Table projection uses single-quote fragment for the literal filter tail
    # to keep shellcheck happy (no embedded double quotes in double-quoted
    # strings).
    local table_filter
    table_filter="${base_filter}"' | .[] | [.name, .type, (.enabled | tostring), (.hosts | join(",")), (.cpus | tostring), .ram, .id] | @tsv'

    if [ -n "$names_json" ]; then
      jq -r --arg host "$NUCLEUS_HOST" --argjson names "$names_json" "$table_filter" "$MANIFEST"
    else
      jq -r --arg host "$NUCLEUS_HOST" "$table_filter" "$MANIFEST"
    fi | while IFS=$'\t' read -r name type enabled hosts cpus ram id; do
      local ram_bytes ram_gib
      ram_bytes="$(parse_size "$ram")"
      ram_gib="$(( (ram_bytes + 500000000) / 1000000000 ))"
      local state
      state="$(_vm_state "$id" "$running_names")"
      printf '%-20s %-12s %-10s %-8s %-8s %-8s %-10s\n' "$name" "$type" "$enabled" "$state" "$hosts" "$cpus" "${ram_gib}G"
    done
  fi
}

# do_start
#   Starts a single VM, preferring the per-VM start script generated by
#   setup — it encodes hypervisor-specific launch options — and falling back
#   to direct hypervisor invocation when setup has not run yet.
do_start() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  if [ "${#filtered_vm_args[@]}" -eq 0 ]; then
    error "start requires a VM name"
    usage >&2
    exit 1
  fi

  local vm_name="${filtered_vm_args[0]}"
  local resolved
  resolved="$(resolve_target_vm "$vm_name")" || exit 1

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"

  local start_script="$VM_DIR/scripts/start-${vm_name}.sh"
  if [ -f "$start_script" ] && [ -x "$start_script" ]; then
    say "starting VM '$vm_name' via generated script..."
    exec "$start_script"
  fi

  # Fallback: direct hypervisor invocation (no script = setup not run)
  local vm_type vm_index
  vm_type="$(printf '%s' "$resolved" | cut -f1)"
  vm_index="$(printf '%s' "$resolved" | cut -f2)"

  case "$(uname -s)" in
    Darwin)
      case "$vm_type" in
        macOS)
          require_command tart "brew install cirruslabs/cli/tart"
          exec tart run "$vm_name"
          ;;
        *)
          # UTM guests
          if command -v utmctl >/dev/null 2>&1; then
            exec utmctl start "$vm_name"
          fi
          local bundle="$VM_DIR/${vm_name}.utm"
          if [ -d "$bundle" ]; then
            exec open "$bundle"
          fi
          error "cannot start '$vm_name': no generated script, utmctl not found, and no UTM bundle at $bundle"
          exit 1
          ;;
      esac
      ;;
    Linux)
      require_command virsh
      exec virsh start "$vm_name"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local win_script="$VM_DIR/scripts/start-${vm_name}.ps1"
      if [ -f "$win_script" ]; then
        exec pwsh -File "$win_script"
      fi
      error "cannot start '$vm_name': no start script at $win_script"
      exit 1
      ;;
  esac
}

# do_stop
#   Stops a single VM, preferring the generated stop script like do_start.
#   WHY: on Linux, ACPI shutdown (virsh shutdown) is tried first so the
#   guest flushes state; virsh destroy is reserved for hung guests.
do_stop() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  if [ "${#filtered_vm_args[@]}" -eq 0 ]; then
    error "stop requires a VM name"
    usage >&2
    exit 1
  fi

  local vm_name="${filtered_vm_args[0]}"
  local resolved
  resolved="$(resolve_target_vm "$vm_name")" || exit 1

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"

  local stop_script="$VM_DIR/scripts/stop-${vm_name}.sh"
  if [ -f "$stop_script" ] && [ -x "$stop_script" ]; then
    say "stopping VM '$vm_name' via generated script..."
    exec "$stop_script"
  fi

  # Fallback: direct hypervisor invocation
  local vm_type vm_index
  vm_type="$(printf '%s' "$resolved" | cut -f1)"
  vm_index="$(printf '%s' "$resolved" | cut -f2)"

  case "$(uname -s)" in
    Darwin)
      case "$vm_type" in
        macOS)
          require_command tart
          exec tart stop "$vm_name"
          ;;
        *)
          require_command utmctl
          exec utmctl stop "$vm_name"
          ;;
      esac
      ;;
    Linux)
      require_command virsh
      if virsh shutdown "$vm_name" 2>/dev/null; then
        say "ACPI shutdown signal sent to '$vm_name'"
      else
        warn "virsh shutdown failed; trying virsh destroy..."
        exec virsh destroy "$vm_name"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local win_script="$VM_DIR/scripts/stop-${vm_name}.ps1"
      if [ -f "$win_script" ]; then
        exec pwsh -File "$win_script"
      fi
      error "cannot stop '$vm_name': no stop script at $win_script"
      exit 1
      ;;
  esac
}

# do_upgrade
#   Re-downloads and replaces the OS image of an Android VM. WHY: only
#   Android consumes a standalone downloaded GSI image (hence the license
#   flag); the other types are built locally from the manifest, so an
#   "upgrade" errors out rather than silently rebuilding.
do_upgrade() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  if [ "${#filtered_vm_args[@]}" -eq 0 ]; then
    error "upgrade requires a VM name"
    usage >&2
    exit 1
  fi

  local vm_name="${filtered_vm_args[0]}"
  local vm_type vm_index
  local resolved
  resolved="$(resolve_target_vm "$vm_name")" || exit 1
  vm_type="$(printf '%s' "$resolved" | cut -f1)"
  vm_index="$(printf '%s' "$resolved" | cut -f2)"

  if [ "$vm_type" != "Android" ]; then
    error "upgrade is only supported for Android VMs ('$vm_name' is type $vm_type)"
    exit 1
  fi

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"
  IMAGES_DIR="$VM_DIR/images"

  if ! resolve_vm_guest_credentials; then
    error "cannot upgrade '$vm_name' — guest credential resolution failed"
    exit 1
  fi
  vm_guest_credentials_fingerprint="$(vm_guest_credentials_hash)"

  vm_init "$REPO_ROOT" "$VM_DIR" "$IMAGES_DIR" "$TEMPLATES_DIR" "$dry_run" \
    "$windows_iso" "$windows_iso_source" "$windows_iso_retries" \
    "$windows_headless" "$accelerator" "$vm_secret_owner" "$vm_guest_username" \
    "$vm_guest_password" "$vm_guest_credentials_fingerprint" \
    "$NUCLEUS_MIDO_PATCH_FILE" "$NUCLEUS_MIDO_SCRIPT" \
    "$accept_gsi_license" "true" "false" \
    "$VMS_DIR" "$MANIFEST" "$NUCLEUS_HOST" "$gc_disabled_mode" "$force"

  vm_build_android "$vm_name" "$vm_index" "$accept_gsi_license" "true" "false"
  say "upgrade complete for '$vm_name'"
}

# do_reset
#   Factory-resets Android VM user state by re-downloading a pristine image.
#   WHY: restricted to Android because the GSI image model is the only one
#   where user state can be discarded cleanly.
do_reset() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"
  require_command jq

  if [ "${#filtered_vm_args[@]}" -eq 0 ]; then
    error "reset requires a VM name"
    usage >&2
    exit 1
  fi

  local vm_name="${filtered_vm_args[0]}"
  local vm_type vm_index
  local resolved
  resolved="$(resolve_target_vm "$vm_name")" || exit 1
  vm_type="$(printf '%s' "$resolved" | cut -f1)"
  vm_index="$(printf '%s' "$resolved" | cut -f2)"

  if [ "$vm_type" != "Android" ]; then
    error "reset is only supported for Android VMs ('$vm_name' is type $vm_type)"
    exit 1
  fi

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"
  IMAGES_DIR="$VM_DIR/images"

  if ! resolve_vm_guest_credentials; then
    error "cannot reset '$vm_name' — guest credential resolution failed"
    exit 1
  fi
  vm_guest_credentials_fingerprint="$(vm_guest_credentials_hash)"

  vm_init "$REPO_ROOT" "$VM_DIR" "$IMAGES_DIR" "$TEMPLATES_DIR" "$dry_run" \
    "$windows_iso" "$windows_iso_source" "$windows_iso_retries" \
    "$windows_headless" "$accelerator" "$vm_secret_owner" "$vm_guest_username" \
    "$vm_guest_password" "$vm_guest_credentials_fingerprint" \
    "$NUCLEUS_MIDO_PATCH_FILE" "$NUCLEUS_MIDO_SCRIPT" \
    "$accept_gsi_license" "false" "true" \
    "$VMS_DIR" "$MANIFEST" "$NUCLEUS_HOST" "$gc_disabled_mode" "$force"

  vm_build_android "$vm_name" "$vm_index" "$accept_gsi_license" "false" "true"
  say "reset complete for '$vm_name'"
}

# do_gc
#   Removes stale VM artifacts: non-provisioned VMs, leftover disks, and
#   generation markers. WHY: GC is opt-in (--gc) rather than automatic
#   because artifact deletion is destructive and must stay explicit.
do_gc() {
  REPO_ROOT="${repo_root_override:-$(derive_repo_root)}"
  resolve_manifest
  NUCLEUS_HOST="$(resolve_nucleus_host)"

  VM_DIR="${vm_dir_override:-$HOME/virtual machines}"
  IMAGES_DIR="$VM_DIR/images"

  require_command jq

  vm_gc_vms
  nuc_done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$action" in
  setup|list|status|start|stop|upgrade|reset|gc) "do_$action" ;;
esac
