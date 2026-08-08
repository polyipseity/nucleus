#!/usr/bin/env bash
# Golden render tests for the VM host-kind templates (start-host.ps1,
# stop-posix.sh, stop-host.ps1): rendering each template with the same sed
# chains vm.sh uses must produce helper scripts with no leftover double-underscore
# token placeholders, no legacy {{TOKEN}}, and the expected commands for each
# host kind. The windows-qemu stop render is compared byte-for-byte against the
# canonical golden content (formerly a 36-line heredoc in vm.sh).
#
# Descriptor-driven renders (P7): with vm.sh sourced and a fixture manifest,
# vm_write_start_script/vm_write_stop_script must render start/stop helpers
# from the descriptor JSON document (id/name/type/cpus/ram/portForwards +
# Android images) with no leftover tokens — covering windows-qemu (shared
# start-android-vm.ps1 / start-windows templates) and darwin-utm (posix +
# host dispatcher). vm_unpack_vms in dry-run mode must plan the regeneration
# without writing any file (scripts/, bundles, disks all stay untouched).
#
# Run with: bash tests/scripts/vm-template-render-tests.sh

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TEMPLATES_DIR="$REPO_ROOT/src/vms/templates"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/size.sh
. "$REPO_ROOT/src/scripts/lib/size.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

_failures=0

render_template() { # render_template <template> <outfile> <-e expr...>
  local _template="$1" _out="$2"; shift 2
  sed "$@" "$TEMPLATES_DIR/$_template" >"$_out"
}

assert_no_tokens() { # assert_no_tokens <file> <label>
  local _file="$1" _label="$2"
  if grep -q '__[A-Z][A-Z_]*__' "$_file"; then
    echo "FAIL: $_label contains leftover __TOKEN__ placeholders:"
    grep -n '__[A-Z][A-Z_]*__' "$_file" | head -5
    _failures=$((_failures + 1))
  fi
  if grep -q '{{' "$_file"; then
    echo "FAIL: $_label contains legacy {{ placeholders"
    grep -n '{{' "$_file" | head -5
    _failures=$((_failures + 1))
  fi
  return 0
}

assert_contains() { # assert_contains <needle> <file> <label>
  local _needle="$1" _file="$2" _label="$3"
  if ! grep -qF -- "$_needle" "$_file"; then
    echo "FAIL: $_label does not contain expected text: $_needle"
    _failures=$((_failures + 1))
  fi
}

assert_absent() { # assert_absent <needle> <file> <label>
  local _needle="$1" _file="$2" _label="$3"
  if grep -qF -- "$_needle" "$_file"; then
    echo "FAIL: $_label contains unexpected text: $_needle"
    grep -nF -- "$_needle" "$_file" | head -5
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
    echo "FAIL: $2: expected file '$1' to be absent"
    _failures=$((_failures + 1))
  fi
}

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

test_start_host_ps1_render() {
  render_template start-host.ps1 "$_tmp/start-testvm.ps1" \
    -e "s|__HOST_KIND__|darwin-tart|g" \
    -e "s|__VM_ID__|testvm|g" \
    -e "s|__VM_DISPLAY__|Test VM|g" \
    -e "s|__VM_DIR__|/virtual machines|g" \
    -e "s|__TART_SOFTNET_EXPOSE__|22010:22|g"
  assert_no_tokens "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  assert_contains "switch ('darwin-tart')" "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  assert_contains '--net-softnet' "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  assert_contains '--net-softnet-expose' "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  assert_contains '22010:22' "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains '& tart run --net-softnet' "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains '$vmName = '\''testvm'\''' "$_tmp/start-testvm.ps1" "start-host.ps1 (darwin-tart)"
}

test_start_posix_sh_darwin_tart_render() {
  render_template start-posix.sh "$_tmp/start-testvm.sh" \
    -e "s|__HOST_KIND__|darwin-tart|g" \
    -e "s|__VM_ID__|testvm|g" \
    -e "s|__VM_DISPLAY__|Test VM|g" \
    -e "s|__VM_TYPE__|macOS|g" \
    -e "s|__VM_DIR__|/virtual machines|g" \
    -e "s|__TART_SOFTNET_EXPOSE__|22010:22|g"
  assert_no_tokens "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains 'HOST_KIND="darwin-tart"' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains '--net-softnet' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains '--net-softnet-expose' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains '22010:22' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains 'exec tart run --net-softnet' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
  assert_contains '"testvm"' "$_tmp/start-testvm.sh" "start-posix.sh (darwin-tart)"
}

test_stop_posix_sh_render() {
  render_template stop-posix.sh "$_tmp/stop-testvm.sh" \
    -e "s|__HOST_KIND__|darwin-utm|g" \
    -e "s|__VM_ID__|testvm|g" \
    -e "s|__VM_DISPLAY__|Test VM|g"
  assert_no_tokens "$_tmp/stop-testvm.sh" "stop-posix.sh (darwin-utm)"
  assert_contains 'HOST_KIND="darwin-utm"' "$_tmp/stop-testvm.sh" "stop-posix.sh (darwin-utm)"
  assert_contains 'exec utmctl stop "Test VM"' "$_tmp/stop-testvm.sh" "stop-posix.sh (darwin-utm)"
  assert_contains 'exec tart stop "testvm"' "$_tmp/stop-testvm.sh" "stop-posix.sh (darwin-utm)"
}

test_stop_host_ps1_windows_golden() {
  render_template stop-host.ps1 "$_tmp/stop-winvm.ps1" \
    -e "s|__HOST_KIND__|windows-qemu|g" \
    -e "s|__VM_ID__|winvm|g"
  assert_no_tokens "$_tmp/stop-winvm.ps1" "stop-host.ps1 (windows-qemu)"

  # Byte-for-byte golden comparison against the canonical content (formerly a
  # 36-line heredoc in vm.sh; backtick-escaped statement dollars were a latent
  # bug, so the golden content uses plain dollars).
  cat >"$_tmp/stop-winvm.golden" <<'GOLDEN'
# Generated by nucleus-vm setup — stop-winvm.ps1. Dispatches to the
# hypervisor selected by windows-qemu (Tart, UTM, libvirt, or QEMU on
# Windows), substituted at VM creation time. VM_NAME is similarly substituted.
#Requires -Version 7.4

$vmName = 'winvm'
$qemuPipe = "\\.\pipe\qga-$vmName"

switch ('windows-qemu') {
  'darwin-tart' {
    & tart stop $vmName
  }
  'darwin-utm' {
    if (Get-Command 'utmctl' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: utmctl optional; absent warns
      & utmctl stop $vmName
    } else {
      Write-Warning "utmctl not found; VM may still be running: $vmName"
    }
  }
  'nixos-libvirt' {
    & virsh shutdown $vmName > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
      & virsh destroy $vmName
    }
  }
  'windows-qemu' {
    $ErrorActionPreference = 'Stop'

    # Try QEMU guest agent shutdown first.
    if (Test-Path -LiteralPath $qemuPipe -PathType Leaf) {
      try {
        Write-Output "Sending guest shutdown via QEMU GA: $vmName"
        # Write the QEMU GA command to the pipe (simplified; a full QMP client
        # would be required for the actual protocol exchange).
        return
      } catch {
        Write-Warning "QEMU GA shutdown failed: $_"
      }
    }

    # Fallback: kill the QEMU process.
    $proc = Get-Process -Name 'qemu-system-*' -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandLine -match "$vmName"
    }
    if ($proc) {
      Write-Output "Stopping QEMU process for VM: $vmName"
      $proc | Stop-Process -Force
    } else {
      Write-Warning "No running QEMU process found for VM: $vmName"
    }
  }
  default {
    Write-Error "nucleus-vm: unknown host kind: windows-qemu"
    exit 1
  }
}
GOLDEN
  # Normalize CRLF (gitattributes sets *.ps1 to CRLF) so the byte comparison
  # is EOL-agnostic; the golden content below is LF.
  tr -d '\r' <"$_tmp/stop-winvm.ps1" >"$_tmp/stop-winvm.lf"
  if ! cmp -s "$_tmp/stop-winvm.golden" "$_tmp/stop-winvm.lf"; then
    echo "FAIL: stop-host.ps1 (windows-qemu) render differs from golden content:"
    diff -u "$_tmp/stop-winvm.golden" "$_tmp/stop-winvm.lf" | head -40
    _failures=$((_failures + 1))
  fi
}

write_fixture_manifest() { # write_fixture_manifest <path> — Android (enabled) + NixOS/Windows (disabled)
  cat >"$1" <<'EOF'
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
      "portForwards": [{"guestPort": 5555, "hostPort": 22040}, {"guestPort": 5554, "hostPort": 22041}],
      "macAddressPrefix": "52",
      "Android": {
        "systemImage": "system image.qcow2",
        "userdataImage": "Android.qcow2",
        "gsiImage": "GSI.img",
        "gsiUrl": "https://example.invalid/gsi.zip",
        "gappsUrl": "https://example.invalid/gapps.zip"
      }
    },
    {
      "id": "MacBook",
      "name": "MacBook",
      "type": "macOS",
      "enabled": false,
      "hosts": ["MacBook"],
      "cpus": 4,
      "ram": "8GB",
      "diskSize": "128GB",
      "portForwards": [{"guestPort": 22, "hostPort": 22010}],
      "macAddressPrefix": "52",
      "macOS": {"version": "tahoe"}
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
}

test_descriptor_fixture_render() {
  local _vm_dir="$_tmp/render/vm" _src_dir="$_tmp/render/vm/src" _vms_dir="$_tmp/render/vms"
  local _manifest="$_tmp/render/manifest.json"
  local _android_doc _nixos_doc _windows_doc _macos_doc

  mkdir -p "$_vm_dir" "$_src_dir" "$_vms_dir"
  write_fixture_manifest "$_manifest"

  vm_init "$REPO_ROOT" "$_vm_dir" "$_src_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "MacBook" "false" "false" "false"
  vm_write_descriptors

  _android_doc="$(cat "$_vm_dir/Android.vm.json")"
  _nixos_doc="$(cat "$_vm_dir/NixOS.vm.json")"
  _windows_doc="$(cat "$_vm_dir/Windows.vm.json")"
  _macos_doc="$(cat "$_vm_dir/MacBook.vm.json")"

  # windows-qemu renders (PowerShell-first): Android renders the shared
  # start-android-vm.ps1 with descriptor-driven tokens (cpus/ram/images/ports);
  # Windows renders start-windows.ps1 + start-windows-host.sh. The .ps1 disk
  # path points at the packed payload (data/<id>.qcow2 under VM_DIR); P8 makes
  # the template path itself relocatable.
  vm_write_start_script "$_android_doc" windows-qemu
  vm_write_start_script "$_windows_doc" windows-qemu
  assert_no_tokens "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 (Android, windows-qemu)"
  assert_no_tokens "$_vm_dir/scripts/start-Android.sh" "start-posix.sh (Android, windows-qemu)"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains "Join-Path \$androidSrcDir 'system image.qcow2'" "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 systemImage token"
  assert_contains "'-smp', '4'," "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 cpus token"
  assert_contains "'-m', '8000000000B'" "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 ram token"
  assert_contains "hostfwd=tcp::22040-:5555,hostfwd=tcp::22041-:5554" "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 portForwards token"
  assert_no_tokens "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 (windows-qemu)"
  assert_no_tokens "$_vm_dir/scripts/start-Windows.sh" "start-windows-host.sh (windows-qemu)"
  assert_contains "-smp 4" "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 cpus token"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains "Windows.qcow2',format=qcow2,if=virtio" "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 packed payload disk path"
  assert_absent "hostfwd=tcp::" "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 empty portForwards render"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains "Windows.qcow2',format=qcow2,if=virtio" "$_vm_dir/scripts/start-Windows.sh" "start-windows-host.sh packed payload disk path"

  # windows-qemu stop: only the .ps1 variant is written (stop-posix.sh cannot
  # dispatch to QEMU); the missing .sh must not fail the render (P7 chmod fix).
  vm_write_stop_script "$_windows_doc" windows-qemu
  assert_no_tokens "$_vm_dir/scripts/stop-Windows.ps1" "stop-host.ps1 (Windows, windows-qemu)"
  assert_contains "switch ('windows-qemu')" "$_vm_dir/scripts/stop-Windows.ps1" "stop-host.ps1 (Windows, windows-qemu)"
  assert_file_missing "$_vm_dir/scripts/stop-Windows.sh" "no stop-Windows.sh for windows-qemu hosts"

  # P8 relocatable-template parity: the windows-qemu start scripts must
  # re-anchor to the tree root before invoking QEMU (relative data/ disk path),
  # and the Android start script must use the shared data/ dir for userdata.
  assert_contains "#!/usr/bin/env bash" "$_vm_dir/scripts/start-Windows.sh" "start-windows-host.sh bash shebang"
  assert_contains "set -euo pipefail" "$_vm_dir/scripts/start-Windows.sh" "start-windows-host.sh strict mode"
  # shellcheck disable=SC2016 # reason: literal $ and quotes in the needle are intentional for grep -F matching of rendered bash
  assert_contains 'cd "$(dirname "$0")/.." || exit 1' "$_vm_dir/scripts/start-Windows.sh" "start-windows-host.sh re-anchors to tree root"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains 'Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)' "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 re-anchors to tree root"
  assert_contains "finally {" "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 restores caller location (finally)"
  assert_contains "Pop-Location" "$_vm_dir/scripts/start-Windows.ps1" "start-windows.ps1 restores caller location (Pop-Location)"
  # shellcheck disable=SC2016 # reason: literal $ in double quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains "Join-Path \$env:USERPROFILE 'virtual machines\data'" "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 shared data dir"
  # shellcheck disable=SC2016 # reason: literal $ in single quotes is intentional for grep -F needle matching of rendered PowerShell
  assert_contains '$diskUserdata = Join-Path $dataDir' "$_vm_dir/scripts/start-Android.ps1" "start-android-vm.ps1 userdata under data/"

  # darwin-utm renders: posix .sh + host-dispatcher .ps1 for every guest type.
  vm_write_start_script "$_android_doc" darwin-utm
  vm_write_start_script "$_nixos_doc" darwin-utm
  vm_write_stop_script "$_nixos_doc" darwin-utm
  assert_no_tokens "$_vm_dir/scripts/start-Android.sh" "start-posix.sh (Android, darwin-utm)"
  assert_no_tokens "$_vm_dir/scripts/start-Android.ps1" "start-host.ps1 (Android, darwin-utm)"
  assert_contains 'HOST_KIND="darwin-utm"' "$_vm_dir/scripts/start-Android.sh" "start-Android.sh host kind"
  assert_contains "switch ('darwin-utm')" "$_vm_dir/scripts/start-Android.ps1" "start-Android.ps1 host kind"
  assert_no_tokens "$_vm_dir/scripts/stop-NixOS.sh" "stop-posix.sh (NixOS, darwin-utm)"
  assert_no_tokens "$_vm_dir/scripts/stop-NixOS.ps1" "stop-host.ps1 (NixOS, darwin-utm)"
  assert_contains 'exec utmctl stop "NixOS"' "$_vm_dir/scripts/stop-NixOS.sh" "stop-NixOS.sh utmctl dispatch"

  # darwin-tart renders: posix .sh + host-dispatcher .ps1 with softnet expose.
  vm_write_start_script "$_macos_doc" darwin-tart
  assert_no_tokens "$_vm_dir/scripts/start-MacBook.sh" "start-posix.sh (MacBook, darwin-tart)"
  assert_no_tokens "$_vm_dir/scripts/start-MacBook.ps1" "start-host.ps1 (MacBook, darwin-tart)"
  assert_contains 'HOST_KIND="darwin-tart"' "$_vm_dir/scripts/start-MacBook.sh" "start-MacBook.sh host kind"
  assert_contains "switch ('darwin-tart')" "$_vm_dir/scripts/start-MacBook.ps1" "start-MacBook.ps1 host kind"
  assert_contains '--net-softnet-expose' "$_vm_dir/scripts/start-MacBook.sh" "start-MacBook.sh softnet expose"
  assert_contains '22010:22' "$_vm_dir/scripts/start-MacBook.sh" "start-MacBook.sh portForwards render"
  assert_contains '22010:22' "$_vm_dir/scripts/start-MacBook.ps1" "start-MacBook.ps1 portForwards render"

  # pack/unpack wrappers are refreshed for the whole tree.
  vm_write_pack_unpack_scripts
  assert_file_exists "$_vm_dir/scripts/pack.sh" "pack.sh wrapper"
  assert_file_exists "$_vm_dir/scripts/unpack.sh" "unpack.sh wrapper"
  assert_file_exists "$_vm_dir/scripts/pack.ps1" "pack.ps1 wrapper"
  assert_file_exists "$_vm_dir/scripts/unpack.ps1" "unpack.ps1 wrapper"
}

test_unpack_dry_run() {
  local _vm_dir="$_tmp/unpack/vm" _src_dir="$_tmp/unpack/vm/src" _vms_dir="$_tmp/unpack/vms"
  local _manifest="$_tmp/unpack/manifest.json" _home_fixture="$_tmp/unpack/home"
  local _out="$_tmp/unpack/out.txt"

  mkdir -p "$_vm_dir" "$_vm_dir/data" "$_src_dir/Android" "$_src_dir/NixOS" "$_src_dir/Windows" "$_vms_dir" \
    "$_home_fixture/.local/share/nucleus/vms"
  write_fixture_manifest "$_manifest"
  # Fixture payload: userdata overlay, Android system/GSI goldens, non-Android
  # prebuilt goldens, and the Nix-rendered UTM plist templates — a packed tree
  # with the target config applied. Dry-run must not touch any of them.
  : >"$_vm_dir/data/Android.qcow2"
  : >"$_src_dir/Android/system image.qcow2"
  : >"$_src_dir/Android/GSI.img"
  : >"$_src_dir/NixOS/prebuilt image.qcow2"
  : >"$_src_dir/Windows/prebuilt image.qcow2"
  : >"$_home_fixture/.local/share/nucleus/vms/Android-config.plist"
  : >"$_home_fixture/.local/share/nucleus/vms/NixOS-config.plist"
  : >"$_home_fixture/.local/share/nucleus/vms/Windows-config.plist"

  vm_init "$REPO_ROOT" "$_vm_dir" "$_src_dir" "$REPO_ROOT/src/vms/templates" \
    "false" "" "" "" "" "" "" "" "" "" "" "" "false" "false" "false" \
    "$_vms_dir" "$_manifest" "MacBook" "false" "false" "false"
  vm_write_descriptors

  # Dry-run unpack on a Darwin/UTM host: HOME points at the fixture so the
  # enabled Android VM reaches its dry-run UTM path; nothing may be written.
  HOME="$_home_fixture" dry_run=true vm_unpack_vms >"$_out" 2>&1 || {
    echo "FAIL: vm_unpack_vms dry-run exited non-zero"
    _failures=$((_failures + 1))
  }

  assert_contains "[dry-run] unpack mode enabled" "$_out" "unpack dry-run banner"
  assert_contains "[dry-run] write start helper scripts:" "$_out" "dry-run start scripts"
  assert_contains "[dry-run] write stop helper scripts:" "$_out" "dry-run stop scripts"
  assert_contains "[dry-run] write pack/unpack helper scripts:" "$_out" "dry-run pack/unpack wrappers"
  assert_contains "[dry-run] recreate UTM bundle" "$_out" "dry-run UTM bundle (enabled Android)"
  assert_contains "descriptor 'NixOS' is disabled; scripts rendered, no bundle/domain" "$_out" "disabled gate (NixOS)"
  assert_contains "descriptor 'Windows' is disabled; scripts rendered, no bundle/domain" "$_out" "disabled gate (Windows)"
  assert_contains "descriptor 'MacBook' is disabled; scripts rendered, no bundle/domain" "$_out" "disabled gate (MacBook)"
  assert_contains "regenerated wrappers for 4 descriptor(s)" "$_out" "unpack summary count"
  assert_contains "unpack — dry-run: nothing was regenerated; pass --force to perform" "$_out" "dry-run completion message"

  # Dry-run plans without writing any helper script file or bundle; the
  # scripts/ directory itself may be created by the planning pass, so the
  # assertions are file-level.
  assert_file_missing "$_vm_dir/scripts/start-Android.sh" "dry-run must not write start scripts"
  assert_file_missing "$_vm_dir/scripts/stop-Windows.ps1" "dry-run must not write stop scripts"
  assert_file_missing "$_vm_dir/scripts/pack.sh" "dry-run must not write pack wrapper"
  if [ -e "$_vm_dir/Android.utm" ]; then
    echo "FAIL: unpack dry-run must not create UTM bundles"
    _failures=$((_failures + 1))
  fi
  # Fixture disks must be untouched (no base copies, no new overlays).
  assert_file_missing "$_src_dir/NixOS/overlay backing.qcow2" "dry-run must not restore overlay backing images"
  assert_file_missing "$_vm_dir/data/NixOS.qcow2" "dry-run must not recreate overlays"
}

test_start_host_ps1_render
test_start_posix_sh_darwin_tart_render
test_stop_posix_sh_render
test_stop_host_ps1_windows_golden
test_descriptor_fixture_render
test_unpack_dry_run

if [ "$_failures" -eq 0 ]; then
  echo "vm-template-render-tests: all checks passed"
  exit 0
fi
echo "vm-template-render-tests: $_failures check(s) failed" >&2
exit 1
