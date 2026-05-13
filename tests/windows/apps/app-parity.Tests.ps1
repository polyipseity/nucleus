# tests/windows/apps/app-parity.Tests.ps1 — Pester coverage for app-specific
# Windows parity managed outside the DSC registry resources.

Describe "Windows Application Parity" {
    Context "QtPass managed registry settings" {
        It "Should configure QtPass clipboard, auto-clear, and visibility values" {
            $qtpass = Get-ItemProperty -Path 'HKCU:\Software\IJHack\QtPass' -ErrorAction SilentlyContinue

            $qtpass.clipBoardType | Should -Be 2
            $qtpass.useAutoclear | Should -Be 1
            $qtpass.autoclearSeconds | Should -Be 10
            $qtpass.useAutoclearPanel | Should -Be 1
            $qtpass.autoclearPanelSeconds | Should -Be 5
            $qtpass.hideContent | Should -Be 0
            $qtpass.hidePassword | Should -Be 1
            $qtpass.useMonospace | Should -Be 1
            $qtpass.displayAsIs | Should -Be 0
            $qtpass.noLineWrapping | Should -Be 0
        }

        It "Should configure QtPass generation, Git, and template values" {
            $qtpass = Get-ItemProperty -Path 'HKCU:\Software\IJHack\QtPass' -ErrorAction SilentlyContinue

            $qtpass.addGPGId | Should -Be 1
            $qtpass.alwaysOnTop | Should -Be 1
            $qtpass.autoPull | Should -Be 0
            $qtpass.autoPush | Should -Be 0
            $qtpass.hideOnClose | Should -Be 1
            $qtpass.passwordCharsselection | Should -Be 0
            $qtpass.passwordLength | Should -Be 15
            $qtpass.passTemplate | Should -Be "login`nurl`ndescription`n"
            $qtpass.startMinimized | Should -Be 0
            $qtpass.templateAllFields | Should -Be 1
            $qtpass.useGit | Should -Be 1
            $qtpass.useOtp | Should -Be 1
            $qtpass.usePwgen | Should -Be 1
            $qtpass.useQrencode | Should -Be 0
            $qtpass.useSelection | Should -Be 0
            $qtpass.useSymbols | Should -Be 1
            $qtpass.useTemplate | Should -Be 1
            $qtpass.useTrayIcon | Should -Be 1
        }
    }

    Context "Obsidian advanced settings parity" {
        It "Should materialize Obsidian config under AppData" {
            $configPath = Join-Path $env:APPDATA 'obsidian\obsidian.json'
            Test-Path -Path $configPath | Should -Be $true
        }

        It "Should disable Obsidian auto-updates and enable the managed advanced settings" {
            $configPath = Join-Path $env:APPDATA 'obsidian\obsidian.json'
            $obsidian = Get-Content -Path $configPath -Raw | ConvertFrom-Json

            $obsidian.updateDisabled | Should -Be $true
            $obsidian.cli | Should -Be $true
            $obsidian.checkSlowStartup | Should -Be $true
        }
    }
}
