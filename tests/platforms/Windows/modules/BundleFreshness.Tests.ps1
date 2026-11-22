<#
.SYNOPSIS
  Pester tests for src/scripts/lib/bundle-freshness.ps1.

.DESCRIPTION
  Verifies that Write-BundleFreshnessNotice reports a stale deployed bundle,
  stays silent when the deployed revision matches HEAD, and never fails the
  caller when history is absent.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/BundleFreshness.Tests.ps1 -Passthru"
#>

BeforeAll {
  $script:HadNoColor = Test-Path Env:\NO_COLOR
  $script:PreviousNoColor = $env:NO_COLOR
  # check-suppress:suppression_doc: deterministic color state for notice output.
  $env:NO_COLOR = '1'
  $outputModule = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Format-NucleusOutput.psm1'
  # check-suppress:suppression_doc: module may not be loaded in a clean test run.
  Remove-Module Format-NucleusOutput -ErrorAction SilentlyContinue
  Import-Module $outputModule -Force -DisableNameChecking

  $libPath = Join-Path $PSScriptRoot '../../../../src/scripts/lib/bundle-freshness.ps1'
  . $libPath
}

AfterAll {
  if ($script:HadNoColor) {
    $env:NO_COLOR = $script:PreviousNoColor
  } else {
    $env:NO_COLOR = $null
  }
}

Describe 'Write-BundleFreshnessNotice' {
  BeforeEach {
    $script:BfStubAppliedRev = $null
    $script:BfStubHeadRev = $null
  }

  It 'stays silent when the deployed revision matches HEAD' {
    $script:BfStubAppliedRev = 'aaaaaaaa'
    $script:BfStubHeadRev = 'aaaaaaaa'
    $output = (Write-BundleFreshnessNotice *>&1 | Out-String).Trim()
    $output | Should -BeNullOrEmpty
  }

  It 'emits one notice when the deployed revision trails HEAD' {
    $script:BfStubAppliedRev = 'aaaaaaaa'
    $script:BfStubHeadRev = 'bbbbbbbb'
    $output = (Write-BundleFreshnessNotice *>&1 | Out-String).Trim()
    $output | Should -Match 'built by an apply at aaaaaaaa'
    $output | Should -Match 'tree is at bbbbbbbb'
    $output | Should -Match 'nucleus-apply'
  }

  It 'stays silent when no apply history is recorded' {
    $script:BfStubAppliedRev = ''
    $script:BfStubHeadRev = 'bbbbbbbb'
    $output = (Write-BundleFreshnessNotice *>&1 | Out-String).Trim()
    $output | Should -BeNullOrEmpty
  }
}
