<#
.SYNOPSIS
    Verifies Windows-side VM disk-model parity (P8): Invoke-VMSetup.ps1 and
    scripts/vm.ps1 must provision writable data disks as data/<id>.qcow2 qcow2
    overlays over src/<type>/system image.qcow2 (backing path tree-root-relative),
    mirroring vm_ensure_data_disk in src/scripts/lib/vm.sh. GC keep-sets,
    grow-only resize, running-VM guards, data preservation, and Android
    standalone userdata must match the POSIX disk model.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Enforces the
    disk-model parity invariant established across P7/P8:

    - The writable data disk is data/<id>.qcow2, rendered RELATIVE in
      generated start scripts (templates re-anchor to the tree root first).
    - The type system image is src/<type>/system image.qcow2; the data disk
      backs it directly and is never recreated/refreshed during setup (data
      preservation), with in-place injection on credential drift while the VM
      is stopped.
    - Data disk growth is grow-only (never shrinks below the manifest size).
    - Android userdata is a standalone qcow2 under data/ (no base).
    - GC orphan sweeps never touch the data/ payload.

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/system/vm-disk-model-parity.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..\")
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\platforms\Windows\modules\system\Invoke-VMSetup.ps1"
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
  It "GC orphan sweeps src/ always and data/ only with -GcData" {
    $content = Get-VmSetupPs1Content
    $content | Should -Match ([regex]::Escape('Get-ChildItem -LiteralPath $srcDir -Directory'))
    $content | Should -Match ([regex]::Escape('if ($gcDataEnabled -and (Test-Path -LiteralPath $dataDir'))
  }

  It "gc.ps1 Step 6 delegates VM-artifact GC to vm.sh gc" {
    $content = Get-GcPs1Content
    $content | Should -Match ([regex]::Escape('& bash $vmSh gc'))
    $content | Should -Not -Match ([regex]::Escape('$_.enabled -eq $true'))
    $content | Should -Not -Match ([regex]::Escape('-Filter "*.qcow2"'))
  }

  It "start-helper renders the runtime disk path relative (data/<id>.qcow2)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('$diskPath = Join-Path ''data'' "$($Vm.id).qcow2"'))
  }

  It "unpack renders the runtime disk path relative (data/<id>.qcow2)" {
    (Get-VmPs1Content) | Should -Match ([regex]::Escape('$diskPath = Join-Path ''data'' "$vmId.qcow2"'))
  }

  It "system image path is tree-root-relative (..\src\<type>\system image.qcow2)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('Get-VMSystemImageRelPath -Type $vm.type'))
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('& $qemuImg create -f qcow2 -b $backingRel -F qcow2 $diskPath'))
  }

  It "data disk creation guards against running VMs and preserves existing disks" {
    $content = Get-VmSetupPs1Content
    $content | Should -Match ([regex]::Escape('Test-VMProcessRunning -VmId $vm.id -VmDisplay $vm.name'))
    $content | Should -Match ([regex]::Escape('function Get-VMRunningProcessNameList'))
    $content | Should -Match ([regex]::Escape('data disk already exists: $diskPath'))
    $content | Should -Match ([regex]::Escape('provision drift detected for'))
    $content | Should -Not -Match ([regex]::Escape('adopting missing provision marker for existing data disk'))
    $content | Should -Not -Match ([regex]::Escape('Copy-Item $prebuilt $basePath'))
  }

  It "list/status share the same QEMU running-process probe as sync" {
    $vmPs1 = Get-VmPs1Content
    $vmPs1 | Should -Match ([regex]::Escape('Get-VMRunningProcessNameList'))
    $vmPs1 | Should -Not -Match ([regex]::Escape("Name = 'qemu-system-x86_64w.exe'"))
  }

  It "data disk growth is grow-only via qemu-img resize" {
    $content = Get-VmSetupPs1Content
    $content | Should -Match ([regex]::Escape('Get-VMQcow2VirtualSize -ImagePath $diskPath'))
    $content | Should -Match ([regex]::Escape('$qemuImg resize $diskPath $diskBytes'))
  }

  It "Android userdata is a standalone data/ qcow2 (no base)" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('Join-Path -Path $dataDir -ChildPath "$($vm.id).qcow2"'))
  }

  It "pack refuses while a VM runs and retains the data/ payload" {
    $content = Get-VmPs1Content
    $content | Should -Match ([regex]::Escape('Get-VMRunningIdList'))
    $content | Should -Match ([regex]::Escape('payload retained (src, data, descriptors, README)'))
  }

  It "POSIX lib mirrors the relative data/ path and data-disk provisioning" {
    $content = Get-VmShLibContent
    $content | Should -Match ([regex]::Escape('_wss_disk_path="data/${_wss_id}.qcow2"'))
    $content | Should -Match ([regex]::Escape('vm_ensure_data_disk'))
  }

  It "pack.ps1 wrappers propagate exit codes in both renderers" {
    (Get-VmSetupPs1Content) | Should -Match ([regex]::Escape('exit $LASTEXITCODE'))
    (Get-VmPs1Content) | Should -Match ([regex]::Escape('exit $LASTEXITCODE'))
  }
}
