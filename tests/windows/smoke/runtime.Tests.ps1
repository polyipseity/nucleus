<#
.SYNOPSIS
    Pester smoke coverage for the Windows test suite runtime.
.DESCRIPTION
    Verifies that the test suite executes on the intended platform (Win32NT)
    with a supported PowerShell version (5.0 or newer).
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe "Windows Test Runtime Smoke" {
    It "Should run on Windows" {
        [System.Environment]::OSVersion.Platform | Should -Be 'Win32NT'
    }

    It "Should run on PowerShell 5.0 or newer" {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterThanOrEqual 5
    }
}
