<#
.SYNOPSIS
    Verifies VM guest credentials resolve from the POSIX-canonical user
    registry (src\modules\users.json), and that the Windows-variant
    registry (src\hosts\Windows\users.json) no longer declares vmGuest
    or the non-canonical vscode casing.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Guarantees the
    credential-unification invariant from the VM manifest refactor:
    Resolve-VMGuestCredential reads the same canonical registry as vm.sh
    (src\modules\users.json, top-level user keys without a .users wrapper),
    the Windows-variant registry and schema drop vmGuest entirely, and both
    registries use the canonical vsCode casing for settings overrides.
.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/system/vm-guest-credential.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\hosts\Windows\modules\system\Invoke-VMSetup.ps1"
  $WindowsUsersJsonPath = Join-Path $RepoRoot "src\hosts\Windows\users.json"
  $WindowsUsersSchemaPath = Join-Path $RepoRoot "src\hosts\Windows\users.schema.json"
  $CanonicalUsersJsonPath = Join-Path $RepoRoot "src\modules\users.json"

  # Resolve paths through this closure so PSUseDeclaredVarsMoreThanAssignments
  # sees the path variables read within the BeforeAll scriptblock (It blocks
  # are sibling scopes).
  function Get-VMSetupText { return Get-Content -Raw -Path $InvokeVMSetupPath }
  function Get-WindowsUsersJson { return Get-Content -Raw -Path $WindowsUsersJsonPath | ConvertFrom-Json }
  function Get-WindowsUsersSchema { return Get-Content -Raw -Path $WindowsUsersSchemaPath | ConvertFrom-Json }
  function Get-CanonicalUsersJson { return Get-Content -Raw -Path $CanonicalUsersJsonPath | ConvertFrom-Json }
}

Describe "Resolve-VMGuestCredential reads the POSIX-canonical user registry" {
  It "references the canonical src\modules\users.json registry" {
    (Get-VMSetupText) | Should -Match 'src\\modules\\users\.json'
  }

  It "no longer references the Windows-variant registry path" {
    (Get-VMSetupText) | Should -Not -Match 'src\\hosts\\Windows\\users\.json'
  }

  It "accesses top-level user keys without the .users wrapper" {
    (Get-VMSetupText) | Should -Match '\$userRegistry\.PSObject\.Properties\[\$secretOwner\]'
    (Get-VMSetupText) | Should -Not -Match '\$userRegistry\.users\.PSObject\.Properties'
  }

  It "keeps the vmGuest secret-key reference error message" {
    (Get-VMSetupText) | Should -Match 'vmGuest secret-key references are missing'
  }
}

Describe "Windows-variant user registry drops vmGuest" {
  It "src\hosts\Windows\users.json declares no vmGuest key" {
    $registry = Get-WindowsUsersJson
    $registry.users.polyipseity.PSObject.Properties.Name | Should -Not -Contain 'vmGuest'
  }

  It "src\hosts\Windows\users.schema.json declares no vmGuest property" {
    $schema = Get-WindowsUsersSchema
    $schema.properties.users.additionalProperties.properties.PSObject.Properties.Name | Should -Not -Contain 'vmGuest'
  }
}

Describe "Canonical vsCode casing across user registries" {
  It "src\modules\users.json uses canonical vsCode casing" {
    $registry = Get-CanonicalUsersJson
    $registry.polyipseity.PSObject.Properties.Name | Should -Contain 'vsCode'
    $registry.polyipseity.PSObject.Properties.Name | Should -Not -Contain 'vscode' -CaseSensitive
  }

  It "src\hosts\Windows\users.json uses canonical vsCode casing" {
    $registry = Get-WindowsUsersJson
    $registry.users.polyipseity.PSObject.Properties.Name | Should -Contain 'vsCode'
    $registry.users.polyipseity.PSObject.Properties.Name | Should -Not -Contain 'vscode' -CaseSensitive
  }

  It "src\hosts\Windows\users.schema.json uses canonical vsCode casing" {
    $schema = Get-WindowsUsersSchema
    $schema.properties.users.additionalProperties.properties.PSObject.Properties.Name | Should -Contain 'vsCode'
    $schema.properties.users.additionalProperties.properties.PSObject.Properties.Name | Should -Not -Contain 'vscode' -CaseSensitive
  }
}
