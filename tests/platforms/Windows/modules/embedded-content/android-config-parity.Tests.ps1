<#
.SYNOPSIS
    Verifies android-config cross-host parity: Windows uses native PowerShell modules
    without bash delegation or nucleus-vm recursion.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/embedded-content/android-config-parity.Tests.ps1 -Passthru"
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..\")
  $VmPs1Path = Join-Path $RepoRoot "scripts\vm.ps1"
  $VmShPath = Join-Path $RepoRoot "scripts\vm.sh"
  $ProfilePath = Join-Path $RepoRoot "src\scripts\shell\profile.ps1"
  $InvokeAndroidConfigPath = Join-Path $RepoRoot "src\platforms\Windows\modules\system\Invoke-AndroidConfig.ps1"
  $script:VmAndroidPath = Join-Path $RepoRoot "src\platforms\Windows\modules\system\VMAndroid.ps1"
  $script:CheckPs1Path = Join-Path $RepoRoot "scripts\check.ps1"

  function Get-VmPs1Content { return Get-Content -Raw -Path $VmPs1Path }
  function Get-VmShContent { return Get-Content -Raw -Path $VmShPath }
  function Get-ProfileContent { return Get-Content -Raw -Path $ProfilePath }
  function Get-InvokeAndroidConfigContent { return Get-Content -Raw -Path $InvokeAndroidConfigPath }
}

Describe "Windows android-config native implementation" {
  It "vm.ps1 dot-sources Invoke-AndroidConfig.ps1 and VMAndroid.ps1" {
    $content = Get-VmPs1Content
    $content | Should -Match ([regex]::Escape("Invoke-AndroidConfig.ps1"))
    $content | Should -Match ([regex]::Escape("VMAndroid.ps1"))
    $content | Should -Match "Invoke-AndroidConfig\s+-RepoRoot"
  }

  It "vm.ps1 does not delegate android-config to bash or nucleus-vm recursion" {
    $content = Get-VmPs1Content
    $content | Should -Not -Match "& nucleus-vm android-config"
    $content | Should -Not -Match "vm\.sh android-config"
    $content | Should -Not -Match "android-config\.sh"
  }

  It "Invoke-AndroidConfig.ps1 declares all paired flags" {
    $content = Get-InvokeAndroidConfigContent
    foreach ($flag in @('--gapps', '--adb-keys', '--magisk', '--root', '--fake-wifi', '--fake-wifi-revert')) {
      $content | Should -Match ([regex]::Escape($flag))
    }
  }

  It "POSIX vm.sh wires android-config.sh" {
    $content = Get-VmShContent
    $content | Should -Match "android-config\.sh"
    $content | Should -Match "do_android_config"
  }
}

Describe "PowerShell shellcheck enforcement" {
  It "profile.ps1 completes nucleus-check and never delegates shell linting" {
    $content = Get-ProfileContent
    $content | Should -Match ([regex]::Escape("Register-ArgumentCompleter -CommandName nucleus-check"))
    $content | Should -Not -Match ([regex]::Escape("scripts\check-sh"))
  }

  It "check.ps1 inlines the shellcheck lint and calls shellcheck directly" {
    Test-Path -LiteralPath $script:CheckPs1Path -PathType Leaf | Should -Be $true
    $checkContent = Get-Content -Raw -Path $script:CheckPs1Path
    $checkContent | Should -Match "function Invoke-CheckSh"
    $checkContent | Should -Match "Invoke-CheckSh @ShPaths"
    $checkContent | Should -Match "shellcheck"
    $checkContent | Should -Match "-S style"
    # The Windows lint lives in the entry point itself: there is no separate
    # check-sh.ps1 to call, and the POSIX body (check-sh.sh) is inlined in check.sh.
    $checkContent | Should -Not -Match "check-sh\.sh"
    $checkContent | Should -Not -Match "&[^\r\n]*check-sh\.ps1"
  }
}

Describe "Android module files exist" {
  It "Invoke-AndroidConfig.ps1 and VMAndroid.ps1 are present" {
    Test-Path -LiteralPath $InvokeAndroidConfigPath -PathType Leaf | Should -Be $true
    Test-Path -LiteralPath $script:VmAndroidPath -PathType Leaf | Should -Be $true
  }
}
