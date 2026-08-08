<#
.SYNOPSIS
    Verifies the Android QEMU start script (src/scripts/vms/start-android-vm.ps1)
    remains the single source of truth: vm.sh (windows-qemu start script
    generation) and Start-AndroidVM.ps1 (Windows entry point) must both
    reference the shared file rather than embedding duplicate copies.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Enforces the
    embedded-content policy "shared cross-platform content" rule:

    - src/scripts/vms/start-android-vm.ps1 is the canonical Android QEMU
      start script (contains the QEMU argument list).
    - vm.sh must render the generated start-<name>.ps1 from the shared file,
      not embed a literal copy of the QEMU arguments.
    - Start-AndroidVM.ps1 must be a thin wrapper delegating to the shared
      file, not a duplicate implementation.

    The canonical file's QEMU argument list is identified by the
    'androidboot.hardware=android_x86_64' kernel flag, which is unique to the
    Android start script and would survive any cosmetic drift.

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/embedded-content/android-vm-single-source.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $AndroidStartScriptPath = Join-Path $RepoRoot "src\scripts\vms\start-android-vm.ps1"
  $VmShPath = Join-Path $RepoRoot "src\scripts\lib\vm.sh"
  $StartAndroidVMPath = Join-Path $RepoRoot "src\platforms\Windows\modules\user\Start-AndroidVM.ps1"

  # Path variables are read through these closures so PSUseDeclaredVarsMoreThanAssignments
  # sees them used within the BeforeAll scriptblock (It blocks are sibling scopes).
  function Get-AndroidStartScriptContent { return Get-Content -Raw -Path $AndroidStartScriptPath }
  function Get-VmShContent { return Get-Content -Raw -Path $VmShPath }
  function Get-StartAndroidVMContent { return Get-Content -Raw -Path $StartAndroidVMPath }
}

Describe "Android VM start script single source" {
  It "shared file exists at src/scripts/vms/start-android-vm.ps1" {
    Test-Path -Path $AndroidStartScriptPath -PathType Leaf | Should -Be $true
  }

  It "shared file contains the canonical Android QEMU argument list" {
    $content = Get-AndroidStartScriptContent
    $content | Should -Match ([regex]::Escape("'-machine', 'virt'"))
    $content | Should -Match ([regex]::Escape("androidboot.hardware=android_x86_64"))
  }

  It "vm.sh renders the start script from the shared file" {
    $vmShContent = Get-VmShContent
    $vmShContent | Should -Match ([regex]::Escape('$REPO_ROOT/src/scripts/vms/start-android-vm.ps1'))
  }

  It "vm.sh does not embed a duplicate Android QEMU argument list" {
    $vmShContent = Get-VmShContent
    $vmShContent | Should -Not -Match ([regex]::Escape("androidboot.hardware=android_x86_64"))
  }

  It "Start-AndroidVM.ps1 is a thin wrapper delegating to the shared file" {
    $wrapperContent = Get-StartAndroidVMContent
    $wrapperContent | Should -Match ([regex]::Escape("..\..\..\..\scripts\vms\start-android-vm.ps1"))
    $wrapperContent | Should -Not -Match ([regex]::Escape("androidboot.hardware=android_x86_64"))
    $wrapperContent | Should -Not -Match ([regex]::Escape("'-machine', 'virt'"))
  }
}

Describe "No legacy token syntax in Android VM start chain" {
  It "shared file and wrapper contain no {{ placeholders" {
    (Get-AndroidStartScriptContent) | Should -Not -Match '\{\{[A-Za-z_]'
    (Get-StartAndroidVMContent) | Should -Not -Match '\{\{[A-Za-z_]'
  }
}
