<#
.SYNOPSIS
    Verifies VM guest credentials resolve from src/users/<username>/vm-guest.json
    via Load-UserRegistry.ps1 / load-user-registry.sh.
.DESCRIPTION
    Static analysis tests (parse files, do not execute). Guarantees the
    credential-unification invariant from the user-registry refactor:
    Resolve-VMGuestCredential reads the assembled src/users/ registry,
    vm-guest.json declares secret-key references for polyipseity, and
    vm.sh uses load-user-registry.sh.
.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/system/vm-guest-credential.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\hosts\Windows\modules\system\Invoke-VMSetup.ps1"
  $VmGuestJsonPath = Join-Path $RepoRoot "src\users\polyipseity\vm-guest.json"
  $VmShPath = Join-Path $RepoRoot "scripts\vm.sh"
  $LoadUserRegistryPath = Join-Path $RepoRoot "src\scripts\lib\load-user-registry.sh"

  function Get-VMSetupText { return Get-Content -Raw -Path $InvokeVMSetupPath }
  function Get-VmGuestJson { return Get-Content -Raw -Path $VmGuestJsonPath | ConvertFrom-Json }
  function Get-VmShText { return Get-Content -Raw -Path $VmShPath }
  function Get-LoadUserRegistryText { return Get-Content -Raw -Path $LoadUserRegistryPath }
}

Describe "Resolve-VMGuestCredential reads the assembled src/users/ registry" {
  It "loads the user registry via Load-UserRegistry.ps1" {
    (Get-VMSetupText) | Should -Match 'Load-UserRegistry\.ps1'
  }

  It "does not reference the removed users.json monolith paths" {
    (Get-VMSetupText) | Should -Not -Match 'src\\modules\\users\.json'
    (Get-VMSetupText) | Should -Not -Match 'src\\hosts\\Windows\\users\.json'
  }

  It "keeps the vmGuest secret-key reference error message" {
    (Get-VMSetupText) | Should -Match 'vmGuest secret-key references are missing'
  }
}

Describe "polyipseity vm-guest.json declares secret-key references" {
  It "src\users\polyipseity\vm-guest.json declares usernameSecretKey" {
    $vmGuest = Get-VmGuestJson
    $vmGuest.usernameSecretKey | Should -Be 'vm_guest_username'
  }

  It "src\users\polyipseity\vm-guest.json declares passwordSecretKey" {
    $vmGuest = Get-VmGuestJson
    $vmGuest.passwordSecretKey | Should -Be 'vm_guest_password'
  }
}

Describe "POSIX vm.sh uses load-user-registry.sh" {
  It "references load-user-registry.sh" {
    (Get-VmShText) | Should -Match 'load-user-registry\.sh'
  }

  It "references src/users" {
    (Get-VmShText) | Should -Match 'src/users'
  }

  It "does not reference the removed users.json monolith" {
    (Get-VmShText) | Should -Not -Match 'src/modules/users\.json'
  }
}

Describe "load-user-registry.sh assembles vmGuest from domain files" {
  It "merges vm-guest.json domain files" {
    (Get-LoadUserRegistryText) | Should -Match 'vm-guest\.json'
  }
}
