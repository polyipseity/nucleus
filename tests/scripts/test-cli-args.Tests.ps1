# E4: test.ps1 accepts POSIX-style flags.

BeforeAll {
  $Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $Script:Test = Join-Path $Script:RepoRoot 'scripts/test.ps1'
  $Script:Pwsh = (Get-Command pwsh).Source
}

Describe 'test.ps1 argument parsing (E4)' {
  It 'accepts --list-steps' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Test --list-steps 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match '(^|\n)nix-tests(\r?\n|$)'
  }

  It 'accepts --verbose --list-steps without parameter-binding errors' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Test --verbose --list-steps 2>&1
    $text = $out -join "`n"
    $text | Should -Not -Match 'parameter cannot be found'
    $text | Should -Match 'nix-tests'
  }

  It 'accepts --scoped --full --no-verbose --only-steps with --list-steps' {
    $out = & $Script:Pwsh -NoProfile -File $Script:Test --scoped --full --no-verbose --only-steps=nix-tests --list-steps 2>&1
    $text = $out -join "`n"
    $text | Should -Not -Match 'parameter cannot be found'
    $text | Should -Match 'nix-tests'
  }

  It 'accepts --verbose=<ids> spelling' {
    # --list-steps short-circuits; argument must parse cleanly.
    $out = & $Script:Pwsh -NoProfile -File $Script:Test --verbose=nix-tests --list-steps 2>&1
    $text = $out -join "`n"
    $text | Should -Not -Match 'unsupported argument'
    $text | Should -Match 'nix-tests'
  }
}
