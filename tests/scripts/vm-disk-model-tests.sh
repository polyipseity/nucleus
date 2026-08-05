#!/usr/bin/env bash
# Identity derivation parity tests for the VM disk model. The deterministic
# UUID/MAC derivations (Nix source of truth: src/modules/lib/vm-identity.nix,
# consumed by src/hosts/MacBook/vms.nix) are recomputed in shell with
# printf+sha256sum and pinned against the same known vectors as
# tests/modules/vm-setup-tests.nix, so the shell twin (src/scripts/lib/vm.sh)
# cannot drift from Nix. The real shell twin is also sourced and exercised
# through vm_init against a fixture manifest: emitted descriptors are checked
# against a golden object, per-field invariants, and vm-descriptor.schema.json
# via check-jsonschema. Sandboxed qemu-img tests exercise the base/overlay
# provisioning helper (vm_ensure_base_and_overlay): base copy, relative backing
# paths, invalid-overlay skip, drift refresh, and grow-only auto-grow.
#
# Run with: bash tests/scripts/vm-disk-model-tests.sh

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/size.sh
. "$REPO_ROOT/src/scripts/lib/size.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

_failures=0
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

mk_uuid() { # mk_uuid <id> — 8-4-4-4-12 UUID from the SHA-256 of the id
  local _id="$1" _h
  _h=$(printf '%s' "$_id" | sha256sum | cut -d' ' -f1)
  printf '%s-%s-%s-%s-%s' "${_h:0:8}" "${_h:8:4}" "${_h:12:4}" "${_h:16:4}" "${_h:20:12}"
}

mk_mac_address() { # mk_mac_address <id> <prefix> — prefix + 5 hex octets from the SHA-256 of "mac:<id>"
  local _id="$1" _prefix="$2" _h
  _h=$(printf '%s' "mac:$_id" | sha256sum | cut -d' ' -f1)
  printf '%s:%s:%s:%s:%s:%s' "$_prefix" "${_h:0:2}" "${_h:2:2}" "${_h:4:2}" "${_h:6:2}" "${_h:8:2}"
}

assert_eq() { # assert_eq <expected> <actual> <label>
  local _expected="$1" _actual="$2" _label="$3"
  if [ "$_expected" != "$_actual" ]; then
    echo "FAIL: $_label: expected '$_expected', got '$_actual'"
    _failures=$((_failures + 1))
  fi
}

test_uuid_vectors() {
  assert_eq "6d612a86-bee4-b0a6-59b8-b3affd6f1fbc" "$(mk_uuid Android)" "UUID Android"
  assert_eq "ac92e761-3044-a456-82e8-cf01eb2471d0" "$(mk_uuid MacBook)" "UUID MacBook"
  assert_eq "cdf51633-aff8-ffbd-4feb-c43ff4de3f1c" "$(mk_uuid NixOS)" "UUID NixOS"
  assert_eq "d598026a-9cbc-6050-5f13-8ce53ac78088" "$(mk_uuid Windows)" "UUID Windows"
}

test_mac_vectors() {
  assert_eq "52:dd:a9:e1:f8:66" "$(mk_mac_address Android 52)" "MAC Android"
  assert_eq "52:d2:6b:37:60:34" "$(mk_mac_address MacBook 52)" "MAC MacBook"
}

test_deterministic() {
  local _first _second
  _first=$(mk_uuid Android)
  _second=$(mk_uuid Android)
  assert_eq "$_first" "$_second" "UUID derivation is deterministic"
}

test_real_helper_vectors() {
  assert_eq "6d612a86-bee4-b0a6-59b8-b3affd6f1fbc" "$(vm_mk_uuid Android)" "vm_mk_uuid Android"
  assert_eq "ac92e761-3044-a456-82e8-cf01eb2471d0" "$(vm_mk_uuid MacBook)" "vm_mk_uuid MacBook"
  assert_eq "52:dd:a9:e1:f8:66" "$(vm_mk_mac_address Android 52)" "vm_mk_mac_address Android"
  assert_eq "52:d2:6b:37:60:34" "$(vm_mk_mac_address MacBook 52)" "vm_mk_mac_address MacBook"
}

test_descriptor_writer() {
  local _vm_dir="$_tmp/vm" _images_dir="$_tmp/vm/images" _vms_dir="$_tmp/vms"
  local _manifest="$_tmp/manifest.json" _android_desc _nixos_desc _windows_desc

  mkdir -p "$_vm_dir" "$_images_dir" "$_vms_dir"

  cat > "$_manifest" <<'EOF'
{
  "VMs": [
    {
      "id": "Android",
      "name": "Android",
      "type": "Android",
      "enabled": true,
      "hosts": ["MacBook", "NixOS", "Windows"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "64GB",
      "portForwards": [{"guestPort": 5555, "hostPort": 5555}, {"guestPort": 5554, "hostPort": 5554}],
      "macAddressPrefix": "52",
      "Android": {
        "systemImage": "Android-system.qcow2",
        "userdataImage": "Android.qcow2",
        "gsiImage": "Android-gsi.img",
        "gsiUrl": "https://example.invalid/gsi.zip"
      }
    },
    {
      "id": "NixOS",
      "name": "NixOS",
      "type": "NixOS",
      "enabled": false,
      "hosts": ["NixOS"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "64GB",
      "portForwards": [],
      "macAddressPrefix": "52"
    },
    {
      "id": "Windows",
      "name": "Windows",
      "type": "Windows",
      "enabled": false,
      "hosts": ["Windows"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "128GB",
      "portForwards": [],
      "macAddressPrefix": "52",
      "Windows": {"edition": "pro", "isoUrl": null}
    }
  ]
}
EOF

  vm_init "$REPO_ROOT" "$_vm_dir" "$_images_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "MacBook" "false" "false"

  vm_write_descriptors

  _android_desc="$_vm_dir/Android.vm.json"
  _nixos_desc="$_vm_dir/NixOS.vm.json"
  _windows_desc="$_vm_dir/Windows.vm.json"

  # Golden descriptor: Android is fully host-independent (fixed aarch64), so
  # the whole emitted object must match field-for-field. -e prints the
  # comparison result to stdout; discard it.
  if ! jq -e --arg schema "$REPO_ROOT/src/modules/vm-descriptor.schema.json" '
    . == {
      "$schema": $schema,
      id: "Android",
      name: "Android",
      type: "Android",
      enabled: true,
      cpus: 4,
      ram: "8GB",
      diskSize: "64GB",
      portForwards: [
        {guestPort: 5555, hostPort: 5555},
        {guestPort: 5554, hostPort: 5554}
      ],
      uuid: "6d612a86-bee4-b0a6-59b8-b3affd6f1fbc",
      mac: "52:dd:a9:e1:f8:66",
      arch: "aarch64",
      machine: "virt",
      uefi: true,
      disks: [
        {role: "system", path: "images/Android-system.qcow2"},
        {role: "gsi", path: "images/Android-gsi.img"},
        {role: "userdata", path: "data/Android.qcow2"}
      ],
      createdBy: "nucleus-vm",
      Android: {
        systemImage: "Android-system.qcow2",
        userdataImage: "Android.qcow2",
        gsiImage: "Android-gsi.img",
        gsiUrl: "https://example.invalid/gsi.zip"
      }
    }
  ' "$_android_desc" >/dev/null; then
    echo "FAIL: descriptor Android golden JSON mismatch"
    _failures=$((_failures + 1))
  fi

  # Windows is also fully host-independent (fixed x86_64).
  assert_eq "d598026a-9cbc-6050-5f13-8ce53ac78088" "$(jq -r .uuid "$_windows_desc")" "descriptor Windows uuid"
  assert_eq "x86_64" "$(jq -r .arch "$_windows_desc")" "descriptor Windows arch"
  assert_eq "q35" "$(jq -r .machine "$_windows_desc")" "descriptor Windows machine"
  assert_eq "false" "$(jq -r .uefi "$_windows_desc")" "descriptor Windows uefi"
  assert_eq "base,runtime" "$(jq -r '.disks | map(.role) | join(",")' "$_windows_desc")" "descriptor Windows disk roles"
  assert_eq "images/Windows.base.qcow2,data/Windows.qcow2" "$(jq -r '.disks | map(.path) | join(",")' "$_windows_desc")" "descriptor Windows disk paths"
  assert_eq "pro" "$(jq -r .Windows.edition "$_windows_desc")" "descriptor Windows group preserved"

  # NixOS arch follows the host; uuid and layout are host-independent. A
  # disabled VM still gets a descriptor (serves scripts/ and unpack).
  assert_eq "cdf51633-aff8-ffbd-4feb-c43ff4de3f1c" "$(jq -r .uuid "$_nixos_desc")" "descriptor NixOS uuid"
  assert_eq "false" "$(jq -r .enabled "$_nixos_desc")" "descriptor written for disabled VM"
  assert_eq "base,runtime" "$(jq -r '.disks | map(.role) | join(",")' "$_nixos_desc")" "descriptor NixOS disk roles"
  assert_eq "images/NixOS.base.qcow2,data/NixOS.qcow2" "$(jq -r '.disks | map(.path) | join(",")' "$_nixos_desc")" "descriptor NixOS disk paths"

  # Emitted descriptors must validate against the repo schema.
  if ! check-jsonschema --schemafile "$REPO_ROOT/src/modules/vm-descriptor.schema.json" \
      "$_android_desc" "$_nixos_desc" "$_windows_desc" >/dev/null; then
    echo "FAIL: emitted descriptors do not validate against vm-descriptor.schema.json"
    _failures=$((_failures + 1))
  fi
}

# Stub: the running-VM probe lives in scripts/vm.sh, not the lib; unit tests
# control it directly.
vm_get_running_names() {
  printf ''
}

# test_base_overlay_provisioning
#   Sandboxed qemu-img tests for vm_ensure_base_and_overlay.  Builds a small
#   pre-built golden image and verifies the five provisioning cases against a
#   scratch VM_DIR.
require_command qemu-img

test_base_overlay_provisioning() {
  local _vm_dir="$_tmp/p2/vm" _images_dir="$_tmp/p2/vm/images" _vms_dir="$_tmp/p2/vms"
  local _manifest="$_tmp/p2/manifest.json"
  local _prebuilt _base _overlay _cred_marker _config_marker
  local _before_hash _after_hash _virtual_size

  mkdir -p "$_vm_dir" "$_images_dir" "$_vms_dir"

  cat > "$_manifest" <<'EOF'
{
  "VMs": [
    {
      "id": "NixOS",
      "name": "NixOS",
      "type": "NixOS",
      "enabled": false,
      "hosts": ["NixOS"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "16GB",
      "portForwards": [],
      "macAddressPrefix": "52"
    }
  ]
}
EOF

  vm_init "$REPO_ROOT" "$_vm_dir" "$_images_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "NixOS" "false" "false"
  vm_guest_credentials_fingerprint="test-fingerprint"

  _prebuilt="$_images_dir/NixOS.qcow2"
  _base="$_images_dir/NixOS.base.qcow2"
  _overlay="$_vm_dir/data/NixOS.qcow2"
  _cred_marker="$(vm_guest_credentials_marker_path NixOS "$_overlay")"
  _config_marker="$(vm_guest_config_marker_path NixOS "$_overlay")"

  qemu-img create -f qcow2 "$_prebuilt" 16M >/dev/null

  # Case 1: base missing → copied from the pre-built golden image.
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  assert_eq "0" "$([ -f "$_base" ] && echo 0 || echo 1)" "base created from prebuilt"

  # Case 2: overlay missing → created with a RELATIVE backing path + markers.
  assert_eq "0" "$([ -f "$_overlay" ] && echo 0 || echo 1)" "overlay created"
  assert_eq "1" "$(qemu-img info "$_overlay" | grep -cF 'backing file: ../images/NixOS.base.qcow2')" "overlay relative backing path"
  assert_eq "test-fingerprint" "$(tr -d '\r\n' <"$_cred_marker")" "credential marker written on overlay create"

  # Case 3: overlay invalid → preserved without --force, recreated with it.
  printf 'garbage' > "$_overlay"
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  assert_eq "garbage" "$(cat "$_overlay")" "invalid overlay preserved without --force"
  force=true
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  force=false
  validate_qcow2_image "$_overlay" "overlay after --force recreate" 0 >/dev/null 2>&1
  assert_eq "0" "$?" "overlay valid after --force recreate"
  assert_eq "test-fingerprint" "$(tr -d '\r\n' <"$_cred_marker")" "credential marker rewritten after --force recreate"

  # Case 4: credential drift → base replaced from prebuilt, overlay + markers refreshed.
  _before_hash="$(vm_sha256_input < "$_overlay")"
  printf 'stale-fingerprint\n' > "$_cred_marker"
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  _after_hash="$(vm_sha256_input < "$_overlay")"
  assert_eq "$_before_hash" "$_after_hash" "overlay preserved across credential drift"
  assert_eq "test-fingerprint" "$(tr -d '\r\n' <"$_cred_marker")" "credential marker refreshed after drift"

  # Case 4b: running VM → base refresh skipped.
  # shellcheck disable=SC2329 # reason: stub invoked indirectly by vm_ensure_base_and_overlay's running-VM guard; shellcheck cannot trace the call
  vm_get_running_names() { printf 'NixOS\n'; }
  printf 'stale-again\n' > "$_cred_marker"
  _before_hash="$(vm_sha256_input < "$_base")"
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  _after_hash="$(vm_sha256_input < "$_base")"
  assert_eq "$_before_hash" "$_after_hash" "base not refreshed while VM is running"
  assert_eq "stale-again" "$(tr -d '\r\n' <"$_cred_marker")" "credential marker not refreshed while VM is running"
  # shellcheck disable=SC2329 # reason: stub restored to empty after indirect use by vm_ensure_base_and_overlay
  vm_get_running_names() { printf ''; }

  # Case 5: grow-only auto-grow (never shrink).
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 33554432 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  _virtual_size="$(qemu-img info --output=json "$_overlay" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_virtual_size" "overlay grown to manifest disk size"
  vm_ensure_base_and_overlay NixOS "$_prebuilt" 0 16777216 "$_cred_marker" "$_config_marker" "" >/dev/null 2>&1
  _virtual_size="$(qemu-img info --output=json "$_overlay" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_virtual_size" "overlay not shrunk when manifest disk size decreased"
}

test_uuid_vectors
test_mac_vectors
test_deterministic
test_real_helper_vectors
test_descriptor_writer
test_base_overlay_provisioning

if [ "$_failures" -eq 0 ]; then
  echo "vm-disk-model-tests: all checks passed"
  exit 0
fi
echo "vm-disk-model-tests: $_failures check(s) failed" >&2
exit 1
