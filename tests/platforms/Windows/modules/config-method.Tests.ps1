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
        It "Should have a # check-suppress:config-method comment near Sync-QtPassConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-QtPassConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-PicardConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-PicardConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-BunConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-BunConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-UvConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-UvConfig' | Should -Be $true
        }

        It "Should have a # check-suppress:config-method comment near Sync-DirenvConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\hosts\Windows\apply.ps1') -Raw
            Test-ConfigMethodLabel -Content $applyContent -Pattern 'Sync-DirenvConfig' | Should -Be $true
        }
    }

    Context "module file path references have method labels" {
        It "Sync-GitAndSshConfig should have # check-suppress:config-method comment near user gitignore symlink" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\platforms\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'userIgnorePath' | Should -Be $true
        }

        It "Sync-GitAndSshConfig should have # check-suppress:config-method comment near user gitconfig symlink" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\platforms\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'userGitConfigPath' | Should -Be $true
        }

        It "Sync-GitAndSshConfig should have # check-suppress:config-method comment near system-scope gitconfig symlink" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\platforms\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'systemConfigPath' | Should -Be $true
        }

        It "Invoke-RustupSetup should have # check-suppress:config-method comment near cargo config" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\platforms\Windows\modules\setup\Invoke-RustupSetup.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'config\.toml' | Should -Be $true
        }

        It "Sync-DirenvConfig should have # check-suppress:config-method comment near source path" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\..\src\platforms\Windows\modules\user\Sync-DirenvConfig.ps1') -Raw
            Test-ConfigMethodLabel -Content $moduleContent -Pattern 'direnvrc' | Should -Be $true
        }
    }
}
