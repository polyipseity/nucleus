# tests/windows/smoke/runtime.Tests.ps1 — Pester smoke coverage proving the
# Windows suite is running on the intended platform and shell runtime.

Describe "Windows Test Runtime Smoke" {
    It "Should run on Windows" {
        [System.Environment]::OSVersion.Platform | Should -Be 'Win32NT'
    }

    It "Should run on PowerShell 5.0 or newer" {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterThanOrEqual 5
    }
}
