# F2: PowerShell floor guard, message shape, and sweep.

BeforeAll {
  $Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $Script:Guard = Join-Path $Script:RepoRoot 'src/scripts/lib/pwsh-guard.ps1'
  $Script:Pwsh = (Get-Command pwsh).Source
  . $Script:Guard
}

Describe 'Assert-NucleusPowerShell (F2)' {
  It 'passes when the requirement is met' {
    { Assert-NucleusPowerShell -Minimum '7.0' } | Should -Not -Throw
  }

  It 'fails with a remediation line when the requirement is unmet' {
    $out = & $Script:Pwsh -NoProfile -Command ". '$($Script:Guard)'; Assert-NucleusPowerShell -Minimum '99.0'" 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    $code | Should -Be 1
    $text | Should -Match 'PowerShell >= 99\.0'
    $text | Should -Match 'pwsh'
    $text | Should -Match 'remediation|install|rerun'
  }

  It 'sweep: directly invocable PowerShell scripts are guarded or explicitly exempt' {
    $exempt = @(
      # sourced libs/loaders/steps/common
      'src/scripts/checks/check-lib.ps1',
      'src/scripts/checks/check-steps.ps1',
      'src/scripts/checks/check-steps/01-code-formatting.ps1',
      'src/scripts/checks/check-steps/02-powershell-lint.ps1',
      'src/scripts/checks/check-steps/05-lockfile-validation.ps1',
      'src/scripts/checks/check-steps/07-schema-validation.ps1',
      'src/scripts/checks/check-steps/08-service-registry.ps1',
      'src/scripts/checks/check-steps/10-completions-fresh.ps1',
      'src/scripts/checks/check-steps/11-repo-policy-grep.ps1',
      'src/scripts/checks/check-steps/12-repo-policy-pattern.ps1',
      'src/scripts/checks/check-steps/13-repo-policy-data.ps1',
      'src/scripts/checks/check-steps/15-app-registry.ps1',
      'src/scripts/checks/lockfile-enforcement-lib.ps1',
      'src/scripts/lib/apply-history.ps1',
      'src/scripts/lib/deny-list.ps1',
      'src/scripts/lib/discord-tray.ps1',
      'src/scripts/lib/nix-test-eval.ps1',
      'src/scripts/lib/pwsh-guard.ps1',
      'src/scripts/lib/step-runner.ps1',
      'src/scripts/notify/harness-bridge-common.ps1',
      'src/scripts/tests/test-lib.ps1',
      'src/scripts/tests/test-steps.ps1',
      'src/scripts/tests/test-steps/01-nix-tests.ps1',
      'src/scripts/tests/test-steps/02-powershell-lint.ps1',
      'src/scripts/tests/test-steps/05-script-and-framework-tests.ps1',
      'src/scripts/tests/test-steps/06-windows-pester.ps1',
      # shell templates/profiles (sourced/config), not standalone entrypoints
      'src/scripts/shell/init.ps1',
      'src/scripts/shell/profile.ps1'
    )
    $files = @(
      Get-ChildItem -Path (Join-Path $Script:RepoRoot 'scripts') -Filter '*.ps1' -File
      Get-ChildItem -Path (Join-Path $Script:RepoRoot 'src/scripts') -Filter '*.ps1' -File -Recurse
    )
    $unguarded = @()
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($Script:RepoRoot.Length).TrimStart([char[]]@('/','\')).Replace('\','/')
      if ($exempt -contains $rel) { continue }
      $text = [System.IO.File]::ReadAllText($f.FullName)
      if ($text -notmatch 'Assert-NucleusPowerShell') {
        $unguarded += $rel
      }
    }
    $unguarded | Should -BeNullOrEmpty
  }
}
