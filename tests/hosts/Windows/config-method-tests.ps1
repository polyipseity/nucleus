<#
.SYNOPSIS
    Validates that Windows-side config deployment has method documentation labels.
.DESCRIPTION
    Ensures apply.ps1 and Windows module files have # check-suppress:config-method comments near
    config file references, matching app-config-policy.instructions.md.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe "Windows config method documentation" {
    BeforeAll {
        function Test-ConfigMethodLabel {
            param(
                [string]$Content,
                [string]$Pattern
            )
            # Returns $true if any line matching $Pattern has a # check-suppress:config-method
            # comment within the preceding 8 lines (covers multi-line comment blocks).
            $lines = $Content -split "`n"
            $hits = @($lines | Select-String -Pattern $Pattern)
            foreach ($hit in $hits) {
                $start = [Math]::Max(0, $hit.LineNumber - 9)
                $end = $hit.LineNumber - 1
                $window = $lines[$start..$end] -join "`n"
                if ($window -match '# check-suppress:config-method') {
                    return $true
                }
            }
            return $false
        }
    }

    Context "apply.ps1 path references have method labels" {
        It "Should have a # check-suppress:config-method comment near qtpassSettingsPath" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'qtpassSettingsPath' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near picardDefaultsPath" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'picardDefaultsPath' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-BunConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-BunConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-UvConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-UvConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-DirenvConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-DirenvConfig' | Should -Be $true
        }
    }

    Context "module file path references have method labels" {
        It "Sync-GitAndSshConfig should have # check-suppress:config-method comment near gitignore symlink" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'system\.gitignore' | Should -Be $true
        }

        It "Sync-GitAndSshConfig should have # check-suppress:config-method comment near Windows.gitconfig" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'Windows\.gitconfig' | Should -Be $true
        }

        It "Invoke-RustupSetup should have # check-suppress:config-method comment near cargo config" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\setup\Invoke-RustupSetup.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'config\.toml' | Should -Be $true
        }

        It "Sync-DirenvConfig should have # check-suppress:config-method comment near source path" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\user\Sync-DirenvConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'direnvrc' | Should -Be $true
        }
    }
}
