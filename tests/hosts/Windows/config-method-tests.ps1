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
            # Check that the qtpass path line has a preceding # Method comment
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
    }
}
