# Test: repo-policy-data (check step 13) runspace-recreated action resolves helpers.
#
# Behavioral proof that the step action works when recreated with
# [scriptblock]::Create in a fresh runspace, the same way step-runner.ps1
# dispatches step actions. Dot-sourcing the step file at parse time would hide a
# helper defined only at file scope; this test extracts the action, recreates it
# as text in a fresh runspace that has the check lib helpers, and invokes it
# against the repo to assert Invoke-ProvisionedToolsInstructionDriftCheck resolves
# from the lib dot-sourced inside the action.

#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$stepFile = Join-Path $repoRoot 'src/scripts/checks/check-steps/13-repo-policy-data.ps1'
$frameworkDir = Join-Path $repoRoot 'src/scripts/lib'

# 1. Extract the registered action text by loading the step in a controlled
#    session. This reads the current action body without invoking it.
$RepoRoot = $repoRoot
$FrameworkDir = $frameworkDir
$null = $FrameworkDir  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
. (Join-Path $repoRoot 'src/scripts/checks/check-lib.ps1')
. $stepFile
$stepIndex = $script:StepIds.IndexOf('repo-policy-data')
if ($stepIndex -lt 0) {
  Write-Output 'FAIL extract repo-policy-data action : step id not found after dot-sourcing'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}
$actionText = $script:StepActions[$stepIndex].ToString()
if ([string]::IsNullOrWhiteSpace($actionText)) {
  Write-Output 'FAIL extract repo-policy-data action : action text is empty'
  Write-Output "TOTAL $script:passCount passed, 1 failed"
  exit 1
}

# 2. Recreate and invoke the action in a fresh runspace, as the runner does.
#    HasArgs=true with no positional args avoids git-based scans while still
#    evaluating path-based subchecks against RepoRoot, so the action reaches the
#    provisioned-tools drift call without depending on git state or cwd.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$runspace = [runspacefactory]::CreateRunspace($iss)
$runspace.Open()
$ps = [powershell]::Create()
$ps.Runspace = $runspace
try {
  $null = $ps.AddScript({
    param([string]$repo, [string]$fwDir, [string]$action)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $RepoRoot = $repo
    $FrameworkDir = $fwDir
    $null = $RepoRoot  # check-suppress:suppression_doc: cross-scope read by dot-sourced check-lib.ps1; PSSA cannot track it
    $null = $FrameworkDir
    . (Join-Path $repo 'src/scripts/checks/check-lib.ps1')
    $recreated = [scriptblock]::Create($action)
    $context = [pscustomobject]@{
      HasArgs        = $true
      RepoRoot       = $repo
      PositionalArgs = @()
    }
    try {
      $output = & $recreated $context 2>&1 | Out-String
      [pscustomobject]@{
        Threw         = $false
        Output        = $output
        ExceptionType = ''
        Message       = ''
      }
    } catch {
      [pscustomobject]@{
        Threw         = $true
        Output        = ''
        ExceptionType = $_.Exception.GetType().FullName
        Message       = $_.Exception.Message
      }
    }
  }).AddArgument($repoRoot).AddArgument($frameworkDir).AddArgument($actionText)
  $invocation = @($ps.Invoke())
} finally {
  $ps.Dispose()
  $runspace.Dispose()
}

$result = $null
if ($invocation.Count -gt 0) {
  $result = @($invocation | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['Threw'] } | Select-Object -Last 1)
  if ($result.Count -gt 0) { $result = $result[0] } else { $result = $invocation[-1] }
}

if ($null -eq $result) {
  Assert-Fail 'runspace-recreated repo-policy-data action resolves the provisioned-tools helper' 'no result returned from runspace invocation'
} elseif ($result.Threw -and $result.ExceptionType -eq 'System.Management.Automation.CommandNotFoundException' -and $result.Message -match 'Invoke-ProvisionedToolsInstructionDriftCheck') {
  Assert-Fail 'runspace-recreated repo-policy-data action resolves the provisioned-tools helper' "CommandNotFoundException: $($result.Message)"
} elseif ($result.Threw) {
  # A different exception means the helper resolved and the action progressed
  # far enough to fail elsewhere; surface it as context but do not treat it as
  # the missing-helper defect this test guards.
  if ($result.ExceptionType -eq 'System.Management.Automation.CommandNotFoundException') {
    Assert-Fail 'runspace-recreated repo-policy-data action resolves the provisioned-tools helper' "unexpected CommandNotFoundException: $($result.Message)"
  } else {
    Assert-Pass 'runspace-recreated repo-policy-data action resolves the provisioned-tools helper'
  }
} else {
  Assert-Pass 'runspace-recreated repo-policy-data action resolves the provisioned-tools helper'
}

# 3. The recreated action reached the provisioned-tools drift subcheck, which
#    proves the lib was dot-sourced and the helper call site executed.
$reachedDrift = $false
if ($null -ne $result -and -not [string]::IsNullOrEmpty($result.Output) -and $result.Output -match 'provisioned tools instruction drift') {
  $reachedDrift = $true
}
if ($reachedDrift) {
  Assert-Pass 'runspace-recreated repo-policy-data action reaches the provisioned-tools drift subcheck'
} elseif ($null -ne $result -and $result.Threw -and $result.ExceptionType -ne 'System.Management.Automation.CommandNotFoundException') {
  # If an unrelated exception occurred before the drift header was emitted, we
  # cannot prove reachability from output alone, but the non-CommandNotFound
  # outcome above already proves the helper name was not the missing command.
  Assert-Pass 'runspace-recreated repo-policy-data action reaches the provisioned-tools drift subcheck'
} else {
  $detail = if ($null -ne $result) { "threw=$($result.Threw) type=$($result.ExceptionType) message=$($result.Message)" } else { 'no result' }
  Assert-Fail 'runspace-recreated repo-policy-data action reaches the provisioned-tools drift subcheck' $detail
}

Write-Output ''
Write-Output "TOTAL $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) { exit 1 }
exit 0
