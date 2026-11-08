<#
.SYNOPSIS
    Pester coverage for the ConvertFrom-WingetLockfileToDsc -EnabledPackages filter.
.DESCRIPTION
    The converter must drop a WinGet package that the enable set excludes while
    keeping every resource it does not own. A Script resource carries its id at
    the resource level, not under settings, so the filter must not treat it as a
    WinGet package and drop it: that regression would silently remove the Scoop
    bootstrap and the font installs from every Windows apply.

    The fixture under tests/fixtures/windows-dsc/ holds four resource shapes: an
    enabled WinGet package with a lockfile pin, a disabled WinGet package, a
    Script resource carrying a document id, and one carrying none.
.NOTES
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'

    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\system\ConvertFrom-WingetLockfileToDsc.ps1')

    # The converter only reads -ConfigPath and writes -OutputPath, so the
    # read-only fixture is used directly and only the outputs live in TestDrive.
    $script:configPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\tests\fixtures\windows-dsc\convert-from-winget-lockfile-to-dsc.dsc.yml'
    $script:lockfilePath = Join-Path -Path $TestDrive -ChildPath 'lockfile.json'
    $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'fixture.locked.dsc.yml'

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
