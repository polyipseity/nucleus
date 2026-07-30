#Requires -Version 7.4
# Test-specific framework library (PowerShell).
# Sources step-runner.ps1 and sets test-specific defaults.

Set-StrictMode -Version Latest

. (Join-Path $FrameworkDir "step-runner.ps1")

$script:FAIL_FAST = $true
$script:skipSystemBuild = $false
$script:usageAction = {
  Write-Output "Usage: test.ps1 [--fail-fast|--no-fail-fast] [--skip-system-build] [--quiet]"
  Write-Output "  Run all Windows-compatible repository test suites."
  Write-Output "  --fail-fast            Exit immediately on first failure (default)."
  Write-Output "  --no-fail-fast          Accumulate all failures."
  Write-Output "  --skip-system-build     No-op (accepted for CLI parity with test.sh)."
  Write-Output "  --quiet                No-op (--quiet is POSIX-only; accepted for CLI parity)."
}

function Write-Message { Write-Output "test: $args" }
function Write-WarningMessage { Write-Output "test: warning: $args" }

$modulesPath = Join-Path $RepoRoot 'src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
Assert-ToolAvailable -Name 'PSScriptAnalyzer' -Type 'Module'

# Override Parse-Args for test-specific flags
function Parse-Args {
  param([string[]]$Args)
  $script:FAIL_FAST = $true
  $script:skipSystemBuild = $false
  $script:SCOPED = $false
  $script:FULL = $false

  $i = 0
  while ($i -lt $Args.Count) {
    switch -Regex ($Args[$i]) {
      '^-h$|^--help$' {
        & $script:usageAction
        exit 0
      }
      '^--fail-fast$' {
        $script:FAIL_FAST = $true
      }
      '^--no-fail-fast$' {
        $script:FAIL_FAST = $false
      }
      '^--skip-system-build$' {
        $script:skipSystemBuild = $true
      }
      '^--quiet$' {
        # No-op: --quiet is POSIX-only.
      }
      '^-.*' {
        Write-ErrorMessage "unsupported argument '$($Args[$i])'"
        & $script:usageAction
        exit 1
      }
      default {
        Write-ErrorMessage "unexpected argument '$($Args[$i])'"
        & $script:usageAction
        exit 1
      }
    }
    $i++
  }
}

# Override Preflight-Check for test-specific tools
function Preflight-Check {
  Assert-ToolAvailable -Name 'PSScriptAnalyzer' -Type 'Module'
}

# Override Run-AllSteps with sequential execution (test steps don't parallelize well)
function Run-AllSteps {
  Initialize-WaveTempDir

  for ($i = 0; $i -lt $script:StepActions.Count; $i++) {
    Invoke-Step -Number $script:StepNumbers[$i] -Name $script:StepNames[$i] -Action $script:StepActions[$i]
  }
}
