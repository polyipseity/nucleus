<#
.SYNOPSIS
    Validates that Windows-side config deployment has method documentation labels.
.DESCRIPTION
    Ensures apply.ps1 and Windows module files have # Method N comments near
    config file references, matching app-config-policy.instructions.md.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe "Windows config method documentation" {
    Context "apply.ps1 path references have method labels" {
        It "Should have a # Method comment near qtpassSettingsPath" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            $qtpassLines = $applyContent -split "`n" | Select-String -Pattern 'qtpassSettingsPath'
            $qtpassLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($applyContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }

        It "Should have a # Method comment near picardDefaultsPath" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            $picardLines = $applyContent -split "`n" | Select-String -Pattern 'picardDefaultsPath'
            $picardLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($applyContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }

        It "Should have a # Method comment near Sync-BunConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            $bunLines = $applyContent -split "`n" | Select-String -Pattern 'Sync-BunConfig'
            $bunLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($applyContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }

        It "Should have a # Method comment near Sync-UvConfig call" {
            $applyContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\apply.ps1') -Raw
            $uvLines = $applyContent -split "`n" | Select-String -Pattern 'Sync-UvConfig'
            $uvLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($applyContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }
    }

    Context "module file path references have method labels" {
        It "Sync-GitAndSshConfig should have # Method comment near gitignore symlink" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\user\Sync-GitAndSshConfig.ps1') -Raw
            $ignoreLines = $moduleContent -split "`n" | Select-String -Pattern 'system\.gitignore'
            $ignoreLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($moduleContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }

        It "Invoke-RustupSetup should have # Method comment near cargo config" {
            $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\..\..\src\hosts\Windows\modules\setup\Invoke-RustupSetup.ps1') -Raw
            $cargoLines = $moduleContent -split "`n" | Select-String -Pattern 'config\.toml'
            $cargoLines | ForEach-Object {
                $lineNum = $_.LineNumber
                $prevLine = ($moduleContent -split "`n")[$lineNum - 2]
                $prevLine -match '# Method' | Should -Be $true
            }
        }
    }
}
