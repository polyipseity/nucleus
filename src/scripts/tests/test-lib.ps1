#Requires -Version 7.4
# Test-specific framework library (PowerShell).
# Sources step-runner.ps1 and sets test-specific defaults.

Set-StrictMode -Version Latest

. (Join-Path $FrameworkDir "step-runner.ps1")

$script:FAIL_FAST = $true
$script:usageAction = {
  Write-Output "Usage: test.ps1 [--fail-fast|--no-fail-fast] [--quiet]"
  Write-Output "  Run all Windows-compatible repository test suites."
  Write-Output "  --fail-fast            Exit immediately on first failure (default)."
  Write-Output "  --no-fail-fast          Accumulate all failures."
  Write-Output "  --quiet                No-op (--quiet is POSIX-only; accepted for CLI parity)."
}

function Write-Message { Write-Output "test: $args" }
function Write-WarningMessage { Write-Output "test: warning: $args" }
function Write-ErrorMessage { Write-Output "test: error: $args" }

$modulesPath = Join-Path $RepoRoot 'src\hosts\Windows\modules'
Import-Module (Join-Path $modulesPath 'Ensure-Tool.psm1') -Force
Assert-ToolAvailable -Name 'PSScriptAnalyzer' -Type 'Module'

# Override Read-Argument for test-specific flags
function Read-Argument {
  param([string[]]$Arguments)
  $script:FAIL_FAST = $true
  $script:HAS_ARGS = $false
  $script:positionalArgs = @()
  $script:SCOPED = $false
  $script:FULL = $false

  $i = 0
  while ($i -lt $Arguments.Count) {
    switch -Regex ($Arguments[$i]) {
      '^-h$|^--help$' {
        & $script:usageAction
        exit 0
        break
      }
      '^--fail-fast$' {
        $script:FAIL_FAST = $true
        break
      }
      '^--no-fail-fast$' {
        $script:FAIL_FAST = $false
        break
      }
      '^--quiet$' {
        # No-op: --quiet is POSIX-only.
        break
      }
      '^-.*' {
        Write-ErrorMessage "unsupported argument '$($Arguments[$i])'"
        & $script:usageAction
        exit 1
        break
      }
      default {
        Write-ErrorMessage "unexpected argument '$($Arguments[$i])'"
        & $script:usageAction
        exit 1
        break
      }
    }
    $i++
  }
}

# Override Test-Prerequisite for test-specific tools
function Test-Prerequisite {
  Assert-ToolAvailable -Name 'PSScriptAnalyzer' -Type 'Module'
}

# Override Invoke-StepPipeline with sequential execution (test steps don't parallelize well)
function Invoke-StepPipeline {
  Initialize-WaveTempDir

  for ($i = 0; $i -lt $script:StepActions.Count; $i++) {
    Invoke-Step -Number $script:StepNumbers[$i] -Name $script:StepNames[$i] -Action $script:StepActions[$i]
  }
}
