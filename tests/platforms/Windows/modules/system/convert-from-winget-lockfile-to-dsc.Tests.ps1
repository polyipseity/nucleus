# convert-from-winget-lockfile-to-dsc.Tests.ps1
# Pester regression tests for the ConvertFrom-WingetLockfileToDsc -EnabledPackages filter.

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\system\ConvertFrom-WingetLockfileToDsc.ps1')

    $script:configPath = Join-Path -Path $TestDrive -ChildPath 'fixture.dsc.yml'
    $script:lockfilePath = Join-Path -Path $TestDrive -ChildPath 'lockfile.json'
    $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'fixture.locked.dsc.yml'

    # Four resource shapes: an enabled WinGet package with a lockfile pin, a
    # disabled WinGet package, a Script resource carrying a document-level id
    # (ScoopInstall), and one carrying none (the Font Awesome block). Only the
    # WinGet packages may be filtered.
    Set-Content -LiteralPath $script:configPath -Value @'
$schema: https://aka.ms/configuration-dsc-schema/0.2
properties:
  configurationVersion: 0.2.0
  resources:
    - resource: Microsoft.WinGet.Client/Package
      directives:
        description: enabled package
      settings:
        id: Example.Enabled
        source: winget

    - resource: Microsoft.WinGet.Client/Package
      directives:
        description: disabled package
      settings:
        id: Example.Disabled
        source: winget

    - resource: PSDscResources/Script
      id: ScoopInstall
      directives:
        description: script resource with a document id
      settings:
        TestScript: |
          return $true
        SetScript: |
          'scoop-install-marker'
      dependsOn:
        - GitInstall

    - resource: PSDscResources/Script
      id: FontAwesomeInstall
      directives:
        description: script resource without a settings id
      settings:
        TestScript: |
          return $true
        SetScript: |
          'font-awesome-marker'
'@

    Set-Content -LiteralPath $script:lockfilePath -Value @'
{
  "winget": {
    "Example.Enabled": "1.2.3"
  },
  "scoop": {}
}
'@

    ConvertFrom-WingetLockfileToDsc `
        -ConfigPath $script:configPath `
        -LockfilePath $script:lockfilePath `
        -OutputPath $script:outputPath `
        -EnabledPackages @{ 'Example.Enabled' = $true }

    $script:locked = Get-Content -LiteralPath $script:outputPath -Raw
}

Describe 'ConvertFrom-WingetLockfileToDsc -EnabledPackages filter' {
    It 'keeps a WinGet package listed in the enabled set' {
        $script:locked | Should -Match '(?m)^        id: Example\.Enabled$'
    }

    It 'drops a WinGet package outside the enabled set' {
        $script:locked | Should -Not -Match 'Example\.Disabled'
    }

    It 'keeps a Script resource that carries a document id' {
        $script:locked | Should -Match '(?m)^      id: ScoopInstall$'
        $script:locked | Should -Match "'scoop-install-marker'"
        $script:locked | Should -Match '(?m)^        - GitInstall$'
    }

    It 'keeps a Script resource that carries no settings id' {
        $script:locked | Should -Match '(?m)^      id: FontAwesomeInstall$'
        $script:locked | Should -Match "'font-awesome-marker'"
    }

    It 'injects the lockfile version into an enabled package' {
        $script:locked | Should -Match '(?m)^        version: 1\.2\.3$'
    }
}
