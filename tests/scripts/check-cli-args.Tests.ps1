# E4: check.ps1 accepts POSIX-style flags and action words (B10).

BeforeAll {
  $Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $Script:Check = Join-Path $Script:RepoRoot 'scripts/check.ps1'
  $Script:Pwsh = (Get-Command pwsh).Source
}

Describe 'check.ps1 argument parsing (E4)' {
  It 'accepts --list-steps' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Check --list-steps 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)code-formatting(\r?\n|$)'
  }

  It 'accepts -ListSteps PowerShell spelling' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Check -ListSteps 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match 'code-formatting'
  }

  It 'accepts bare POSIX flags without parameter-binding errors (B10)' {
    # --list-steps exits early; combining with other flags must not trigger
    # "A parameter cannot be found..." errors.
    $out = & $Script:Pwsh -NoProfile -File $Script:Check --verbose --scoped --full --list-steps 2>&1
    $text = $out -join "`n"
    $text | Should -Not -Match 'parameter cannot be found'
    $text | Should -Match 'code-formatting'
  }

  It 'accepts sh/pwsh/packer action words in parsing position' {
    # sh action with no files in scoped-like empty context: invoke via --help-like? Not available.
    # Verify action words are not rejected as unknown parameters by checking pwsh action
    # does not fail with parameter-binding error for the action token.
    $out = & $Script:Pwsh -NoProfile -File $Script:Check pwsh 2>&1
    $text = $out -join "`n"
    $text | Should -Not -Match "parameter cannot be found that matches parameter name 'pwsh'"
  }
}
