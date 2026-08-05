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
# paths, invalid-overlay skip, drift refresh, and grow-only auto-grow. Sandboxed
# GC tests exercise the keep-set semantics of vm_gc_orphan_disks,
# vm_gc_orphan_markers, and vm_gc_orphan_descriptors under both default and
# --gc-disabled expected sets.
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

assert_file_exists() { # assert_file_exists <path> <label>
  if [ ! -f "$1" ]; then
    echo "FAIL: $2: expected file '$1' to exist"
    _failures=$((_failures + 1))
  fi
}

assert_file_missing() { # assert_file_missing <path> <label>
  if [ -f "$1" ]; then
    echo "FAIL: $2: expected file '$1' to be removed"
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

# test_resize_vm
#   Sandboxed qemu-img tests for vm_resize_vm: grow allowed by default,
#   shrink rejected without --allow-shrink, shrink allowed with the flag,
#   running-VM rejection, and Android resizing data/<id>.qcow2.
test_resize_vm() {
  local _vm_dir="$_tmp/resize/vm" _images_dir="$_tmp/resize/vm/images" _vms_dir="$_tmp/resize/vms"
  local _manifest="$_tmp/resize/manifest.json"
  local _disk _old_size _new_size

  mkdir -p "$_vm_dir" "$_images_dir" "$_vms_dir" "$_vm_dir/data"

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
      "portForwards": [],
      "macAddressPrefix": "52",
      "Android": {"systemImage": "Android-system.qcow2", "userdataImage": "Android.qcow2", "gsiImage": "Android-gsi.img", "gsiUrl": "https://example.invalid/gsi.zip"}
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
    }
  ]
}
EOF

  vm_init "$REPO_ROOT" "$_vm_dir" "$_images_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "NixOS" "false" "false"

  # Grow allowed.
  _disk="$_vm_dir/data/NixOS.qcow2"
  qemu-img create -f qcow2 "$_disk" 16M >/dev/null
  _old_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  vm_resize_vm NixOS 33554432 false >/dev/null 2>&1
  _new_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_new_size" "resize grows disk to target"

  # Shrink rejected without flag.
  if vm_resize_vm NixOS 16777216 false >/dev/null 2>&1; then
    echo "FAIL: shrink without --allow-shrink should fail"
    _failures=$((_failures + 1))
  fi
  _new_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_new_size" "disk unchanged after rejected shrink"

  # Shrink allowed with flag.
  vm_resize_vm NixOS 16777216 true >/dev/null 2>&1
  _new_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  assert_eq "16777216" "$_new_size" "resize shrinks disk with --allow-shrink"

  # Running VM rejection.
  # shellcheck disable=SC2329 # reason: stub invoked indirectly by vm_resize_vm's running-VM guard; shellcheck cannot trace the call
  vm_get_running_names() { printf 'NixOS\n'; }
  if vm_resize_vm NixOS 33554432 false >/dev/null 2>&1; then
    echo "FAIL: resize while running should fail"
    _failures=$((_failures + 1))
  fi
  _new_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  assert_eq "16777216" "$_new_size" "disk unchanged while VM running"
  # shellcheck disable=SC2329 # reason: stub restored to empty after indirect use by vm_resize_vm
  vm_get_running_names() { printf ''; }

  # Android userdata resize targets data/<id>.qcow2.
  _disk="$_vm_dir/data/Android.qcow2"
  qemu-img create -f qcow2 "$_disk" 16M >/dev/null
  vm_resize_vm Android 33554432 false >/dev/null 2>&1
  _new_size="$(qemu-img info --output=json "$_disk" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_new_size" "Android resize targets data/Android.qcow2"

  # Unknown VM rejected.
  if vm_resize_vm Missing 16777216 false >/dev/null 2>&1; then
    echo "FAIL: resize of unknown VM should fail"
    _failures=$((_failures + 1))
  fi
}

# test_resize_and_mark_image_grow_only
#   resize_and_mark_image grows to DISK_BYTES but never shrinks below the
#   current virtual size.
test_resize_and_mark_image_grow_only() {
  local _vm_dir="$_tmp/rmi/vm" _images_dir="$_tmp/rmi/vm/images" _vms_dir="$_tmp/rmi/vms"
  local _manifest="$_tmp/rmi/manifest.json"
  local _img _marker _virtual_size

  mkdir -p "$_vm_dir" "$_images_dir" "$_vms_dir"

  cat > "$_manifest" <<'EOF'
{ "VMs": [] }
EOF

  vm_guest_credentials_fingerprint="test-fingerprint"

  _img="$_images_dir/Test.qcow2"
  _marker="$_images_dir/Test.vm-guest-credentials-sha256"
  qemu-img create -f qcow2 "$_img" 16M >/dev/null

  resize_and_mark_image "$_img" "$_marker" 33554432
  _virtual_size="$(qemu-img info --output=json "$_img" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_virtual_size" "resize_and_mark_image grows to DISK_BYTES"
  assert_eq "test-fingerprint" "$(tr -d '\r\n' <"$_marker")" "marker written after grow"

  resize_and_mark_image "$_img" "$_marker" 16777216
  _virtual_size="$(qemu-img info --output=json "$_img" | jq -r '."virtual-size" // 0')"
  assert_eq "33554432" "$_virtual_size" "resize_and_mark_image never shrinks"
  assert_eq "test-fingerprint" "$(tr -d '\r\n' <"$_marker")" "marker rewritten after no-op resize"
}

# test_gc_keep_set
#   GC keep-sets preserve every manifest-referenced image (goldens, bases,
#   Android system/GSI/userdata, disabled-entries prebuilts by default) while
#   sweeping stale disks, orphaned sidecar markers, name-based markers for
#   un-expected guests, and orphaned descriptors.  --gc-disabled narrows the
#   expected set and clears disabled entries too.
test_gc_keep_set() {
  local _vm_dir="$_tmp/gc/vm" _images_dir="$_tmp/gc/vm/images" _vms_dir="$_tmp/gc/vms"
  local _manifest="$_tmp/gc/manifest.json"
  local _expected _keep

  mkdir -p "$_vm_dir" "$_images_dir" "$_vm_dir/data" "$_vms_dir"

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
      "portForwards": [],
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
      "enabled": true,
      "hosts": ["NixOS"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "64GB",
      "portForwards": [],
      "macAddressPrefix": "52"
    },
    {
      "id": "MacBook",
      "name": "MacBook",
      "type": "macOS",
      "enabled": true,
      "hosts": ["MacBook"],
      "cpus": 4,
      "ram": "16GB",
      "diskSize": "128GB",
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
      "macAddressPrefix": "52"
    }
  ]
}
EOF

  vm_init "$REPO_ROOT" "$_vm_dir" "$_images_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "NixOS" "false" "false"

  # Files that must survive default GC (host NixOS; manifest holds all four
  # guests): Android system/GSI/userdata, NixOS golden+base+overlay, macOS
  # base (type-prefixed keep), Windows golden (disabled entry preserved).
  : > "$_images_dir/Android-system.qcow2"
  : > "$_images_dir/Android-gsi.img"
  : > "$_images_dir/NixOS.qcow2"
  : > "$_images_dir/NixOS.base.qcow2"
  : > "$_images_dir/macOS.base.qcow2"
  : > "$_images_dir/Windows.qcow2"
  : > "$_vm_dir/data/Android.qcow2"
  : > "$_vm_dir/data/NixOS.qcow2"
  : > "$_vm_dir/data/Windows.qcow2"

  # Stale disk images in both directories.
  : > "$_images_dir/stale.qcow2"
  : > "$_vm_dir/data/stale.qcow2"

  # Sidecar markers (data/) and name-based markers (images/).
  : > "$_vm_dir/data/NixOS.qcow2.vm-guest-credentials-sha256"
  : > "$_vm_dir/data/stale.qcow2.vm-guest-credentials-sha256"
  : > "$_images_dir/NixOS.vm-guest-credentials-sha256"
  : > "$_images_dir/Android.vm-guest-config-sha256"
  : > "$_images_dir/MacBook.vm-guest-credentials-sha256"
  : > "$_images_dir/Windows.vm-guest-credentials-sha256"

  # Descriptors for every guest plus one stale entry.
  vm_write_descriptors
  : > "$_vm_dir/stale.vm.json"

  _expected="$(vm_get_manifest_vm_names)"
  vm_gc_orphan_disks "$_expected"
  vm_gc_orphan_markers "$_expected"
  vm_gc_orphan_descriptors "$_expected"

  for _keep in Android-system.qcow2 NixOS.qcow2 NixOS.base.qcow2 macOS.base.qcow2 Windows.qcow2; do
    assert_file_exists "$_images_dir/$_keep" "default GC kept image images/$_keep"
  done
  assert_file_exists "$_images_dir/Android-gsi.img" "default GC kept Android GSI image"
  for _keep in Android.qcow2 NixOS.qcow2 Windows.qcow2; do
    assert_file_exists "$_vm_dir/data/$_keep" "default GC kept overlay data/$_keep"
  done
  assert_file_missing "$_images_dir/stale.qcow2" "default GC removed stale image images/stale.qcow2"
  assert_file_missing "$_vm_dir/data/stale.qcow2" "default GC removed stale overlay data/stale.qcow2"

  # Sidecar markers follow their disk; name-based markers survive while the
  # guest is expected (including macOS/tart, which has no local qcow2 base).
  assert_file_exists "$_vm_dir/data/NixOS.qcow2.vm-guest-credentials-sha256" "default GC kept live sidecar marker"
  assert_file_missing "$_vm_dir/data/stale.qcow2.vm-guest-credentials-sha256" "default GC removed orphaned sidecar marker"
  for _keep in NixOS.vm-guest-credentials-sha256 Android.vm-guest-config-sha256 MacBook.vm-guest-credentials-sha256 Windows.vm-guest-credentials-sha256; do
    assert_file_exists "$_images_dir/$_keep" "default GC kept live name-based marker $_keep"
  done

  for _keep in Android.vm.json NixOS.vm.json MacBook.vm.json Windows.vm.json; do
    assert_file_exists "$_vm_dir/$_keep" "default GC kept descriptor $_keep"
  done
  assert_file_missing "$_vm_dir/stale.vm.json" "default GC removed orphaned descriptor stale.vm.json"

  # --gc-disabled narrows the expected set to enabled-and-host-matched VMs
  # (Android, NixOS on host NixOS): disabled-entries artifacts are cleared.
  _expected="$(vm_get_expected_vm_names)"
  vm_gc_orphan_disks "$_expected"
  vm_gc_orphan_markers "$_expected"
  vm_gc_orphan_descriptors "$_expected"

  assert_file_missing "$_images_dir/Windows.qcow2" "gc-disabled removed disabled prebuilt images/Windows.qcow2"
  assert_file_missing "$_images_dir/macOS.base.qcow2" "gc-disabled removed disabled base images/macOS.base.qcow2"
  assert_file_missing "$_vm_dir/data/Windows.qcow2" "gc-disabled removed disabled overlay data/Windows.qcow2"
  assert_file_missing "$_images_dir/Windows.vm-guest-credentials-sha256" "gc-disabled removed disabled name-based marker"
  assert_file_missing "$_images_dir/MacBook.vm-guest-credentials-sha256" "gc-disabled removed tart marker for un-expected guest"
  assert_file_missing "$_vm_dir/Windows.vm.json" "gc-disabled removed disabled descriptor Windows.vm.json"
  assert_file_missing "$_vm_dir/MacBook.vm.json" "gc-disabled removed disabled descriptor MacBook.vm.json"
  for _keep in Android-system.qcow2 NixOS.qcow2 NixOS.base.qcow2; do
    assert_file_exists "$_images_dir/$_keep" "gc-disabled kept image images/$_keep"
  done
  assert_file_exists "$_vm_dir/data/Android.qcow2" "gc-disabled kept Android userdata"
  assert_file_exists "$_vm_dir/data/NixOS.qcow2" "gc-disabled kept NixOS overlay"
}

test_uuid_vectors
test_mac_vectors
test_deterministic
test_real_helper_vectors
test_descriptor_writer
test_base_overlay_provisioning
test_resize_vm
test_resize_and_mark_image_grow_only
test_gc_keep_set

if [ "$_failures" -eq 0 ]; then
  echo "vm-disk-model-tests: all checks passed"
  exit 0
fi
echo "vm-disk-model-tests: $_failures check(s) failed" >&2
exit 1
