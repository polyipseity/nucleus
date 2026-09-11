#Requires -Version 7.4
# Guard: every PowerShell module under src/platforms/Windows must parse.
#
# A dangling '[Parameter(...)]' attribute with no parameter name (as
# Invoke-CamillaDSPSetup.ps1 and Invoke-CamillaGUISetup.ps1 once carried) is a
# parser error: the file cannot be dot-sourced at all.  apply.ps1 dot-sources
# every setup and user module before running a single step, so such a file
# aborts a Windows apply before any convergence happens — and no Windows-only
# test run would report it, because the failure precedes the tests.
#
# Run with: pwsh -NoProfile tests/platforms/Windows/modules/PowerShellSyntax.Tests.ps1

[CmdletBinding()]
param()

BeforeAll {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
  # $script: scope so the It blocks share it (Pester's cross-block convention).
  $script:windowsTree = Join-Path $repoRoot 'src/platforms/Windows'
}

Describe 'Windows PowerShell module syntax' {
  It 'finds the Windows module tree' {
    (Test-Path -LiteralPath $script:windowsTree -PathType Container) | Should -Be $true
  }

  It 'parses every module without errors' {
    $files = @(Get-ChildItem -Path $script:windowsTree -Recurse -Filter '*.ps1' -File)
    # A scan that silently finds nothing would make this guard vacuous.
    $files.Count | Should -BeGreaterThan 50

    $failures = @(foreach ($file in $files) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if ($errors) {
          '{0}: {1}' -f $file.FullName, $errors[0].Message
        }
      })

    $failures | Should -BeNullOrEmpty
  }
}
