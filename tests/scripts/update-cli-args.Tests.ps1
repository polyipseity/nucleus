# E4: update.ps1 accepts POSIX-style spellings and action words.

BeforeAll {
  $Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $Script:Update = Join-Path $Script:RepoRoot 'scripts/update.ps1'
  $Script:Pwsh = (Get-Command pwsh).Source
}

Describe 'update.ps1 argument parsing (E4)' {
  It 'accepts --list-sections and emits bare section names' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Update --list-sections 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)bun(\r?\n|$)'
    ($out -join "`n") | Should -Match '(^|\n)winget(\r?\n|$)'
  }

  It 'accepts lockfile --list-sections' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Update lockfile --list-sections 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)bun(\r?\n|$)'
  }

  It 'accepts -ListSections PowerShell spelling' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Update -ListSections 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)bun(\r?\n|$)'
  }

  It 'accepts --sections=<value> --list-sections (POSIX spelling)' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Update --sections=winget --list-sections 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)winget(\r?\n|$)'
  }
}
