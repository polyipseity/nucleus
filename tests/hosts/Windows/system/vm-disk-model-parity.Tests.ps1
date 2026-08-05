<#
.SYNOPSIS
    Verifies Windows-side VM disk-model parity (P8): Invoke-VMSetup.ps1 and
    scripts/vm.ps1 must provision writable runtime disks as data/<id>.qcow2
    qcow2 overlays over images/<type>.base.qcow2 (base = cp of the prebuilt
    golden, backing path tree-root-relative), mirroring vm_ensure_base_and_overlay
    in src/scripts/lib/vm.sh. GC keep-sets, grow-only resize, running-VM guards,
    and Android standalone userdata must match the POSIX disk model.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Enforces the
    disk-model parity invariant established across P7/P8:

    - The writable runtime disk is data/<id>.qcow2, rendered RELATIVE in
      generated start scripts (templates re-anchor to the tree root first).
    - The base image is images/<type>.base.qcow2, a cp of the kept prebuilt
      golden, refreshed on guest-credential drift while the VM is stopped.
    - Overlay growth is grow-only (never shrinks below the manifest size).
    - Android userdata is a standalone qcow2 under data/ (no base).
    - GC orphan sweeps never touch the data/ payload.

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/system/vm-disk-model-parity.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\hosts\Windows\modules\system\Invoke-VMSetup.ps1"
  $VmPs1Path = Join-Path $RepoRoot "scripts\vm.ps1"
  $VmShLibPath = Join-Path $RepoRoot "src\scripts\lib\vm.sh"
  $GcPs1Path = Join-Path $RepoRoot "scripts\gc.ps1"

  # Path variables are read through these closures so PSUseDeclaredVarsMoreThanAssignments
  # sees them used within the BeforeAll scriptblock (It blocks are sibling scopes).
  function Get-VmSetupPs1Content { return Get-Content -Raw -Path $InvokeVMSetupPath }
  function Get-VmPs1Content { return Get-Content -Raw -Path $VmPs1Path }
  function Get-VmShLibContent { return Get-Content -Raw -Path $VmShLibPath }
  function Get-GcPs1Content { return Get-Content -Raw -Path $GcPs1Path }
}

Describe "Windows VM disk-model parity (P8)" {
  It "GC orphan sweeps limit the keep-set to data/ + images/" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('@($dataDir, $imagesDir)'))
  }

  It "gc.ps1 Step 7 delegates VM-artifact GC to Invoke-VMSetup -Gc" {
    $content = Get-GcPs1Content
    $content | Should -Match ([regex]::Escape('Invoke-VMSetup -RepoRoot $resolvedRepoRoot -Gc'))
    $content | Should -Not -Match ([regex]::Escape('$_.enabled -eq $true'))
    $content | Should -Not -Match ([regex]::Escape('-Filter "*.qcow2"'))
  }

  It "start-helper renders the runtime disk path relative (data/<id>.qcow2)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('$diskPath = Join-Path ''data'' "$($Vm.id).qcow2"'))
  }

  It "unpack renders the runtime disk path relative (data/<id>.qcow2)" {
    (Get-VmPs1Content) | Should -Match ([regex]::Escape('$diskPath = Join-Path ''data'' "$vmId.qcow2"'))
  }

  It "overlay backing path is tree-root-relative (..\images\<type>.base.qcow2)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('$qemuImg create -f qcow2 -b "..\images\$($vm.type).base.qcow2" -F qcow2'))
  }

  It "base refresh copies the prebuilt golden and guards against running VMs" {
    $content = Get-VmSetupPs1Content
    $content | Should -Match ([regex]::Escape('Copy-Item $prebuilt $basePath'))
    $content | Should -Match ([regex]::Escape('Test-VmProcessRunning -VmName $vm.id -VmDisplay $vm.name'))
  }

  It "overlay growth is grow-only via qemu-img resize" {
    $content = Get-VmSetupPs1Content
    $content | Should -Match ([regex]::Escape('Get-VmQcow2VirtualSize -ImagePath $diskPath'))
    $content | Should -Match ([regex]::Escape('$qemuImg resize $diskPath $diskBytes'))
  }

  It "Android userdata is a standalone data/ qcow2 (no base)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('Join-Path -Path $dataDir -ChildPath "$($vm.id).qcow2"'))
  }

  It "pack refuses while a VM runs and retains the data/ payload" {
    $content = Get-VmPs1Content
    $content | Should -Match ([regex]::Escape('Get-VmRunningNameList'))
    $content | Should -Match ([regex]::Escape('payload retained (images, data, descriptors, README)'))
  }

  It "POSIX lib mirrors the relative data/ path and base/overlay provisioning" {
    $content = Get-VmShLibContent
    $content | Should -Match ([regex]::Escape('_wss_disk_path="data/${_wss_name}.qcow2"'))
    $content | Should -Match ([regex]::Escape('vm_ensure_base_and_overlay'))
  }

  It "pack.ps1 wrappers propagate exit codes in both renderers" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('exit $LASTEXITCODE'))
    (Get-VmPs1Content) | Should -Match ([regex]::Escape('exit $LASTEXITCODE'))
  }
}
