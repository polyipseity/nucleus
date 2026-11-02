<#
.SYNOPSIS
    Pester coverage for Sync-SafeDelete's clink resolution.
.DESCRIPTION
    Unit-tests Resolve-ClinkCommand: clink comes from the WinGet DSC entry
    chrisant996.Clink, and nothing in this repo adds a PATH entry for it, so
    whatever Clink's installer put on PATH is the whole search. The v1.9.35
    release archive ships clink.bat, not clink.exe, so clink wins when both
    names resolve, clink_x64 is honoured when only the suffixed binary is
    present, and absence returns $null.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Resolve-ClinkCommand' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\platforms\Windows\modules\user\Sync-SafeDelete.ps1')
    }

    It 'resolves clink from PATH when both names resolve' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink.bat' } } -ParameterFilter { $Name -eq 'clink' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink_x64.exe' } } -ParameterFilter { $Name -eq 'clink_x64' }

        Resolve-ClinkCommand | Should -Be 'C:\Program Files\Clink\clink.bat'
    }

    It 'honours clink_x64 when clink itself is absent' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'clink' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink_x64.exe' } } -ParameterFilter { $Name -eq 'clink_x64' }

        Resolve-ClinkCommand | Should -Be 'C:\Program Files\Clink\clink_x64.exe'
    }

    It 'returns $null when neither clink nor clink_x64 resolves' {
        Mock Get-Command { } -ParameterFilter { $Name -in @('clink', 'clink_x64') }

        Resolve-ClinkCommand | Should -BeNullOrEmpty
    }
}
