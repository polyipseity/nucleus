#Requires -Version 7.4
# Windows lockfile version enforcement check step.
# Sources check-lib.ps1 (provides Write-Message, Write-WarningMessage,
# Write-ErrorMessage, Skip-Step, Get-StepNumber, Register-Step) and the shared
# probe library (Invoke-LockfileEnforcement).
. (Join-Path $PSScriptRoot '..\check-lib.ps1')
. (Join-Path $PSScriptRoot '..\lockfile-enforcement-lib.ps1')

Register-Step -Id "lockfile-enforcement" -Name "Lockfile version enforcement" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if ($HasArgs) {
    $hasLf = $false
    foreach ($f in $PositionalArgs) {
      if ($f -like '*lockfile*.json') { $hasLf = $true; break }
    }
    if (-not $hasLf) {
      Skip-Step -Number (Get-StepNumber) -Name "Lockfile version enforcement" -Reason "no lockfile files to check"
      return 2
    }
  }

  $lockfile = Join-Path $RepoRoot 'src\lockfiles\lockfile.json'
  if (-not (Test-Path $lockfile)) {
    Skip-Step -Number (Get-StepNumber) -Name "Lockfile version enforcement" -Reason "no lockfile present"
    return 2
  }

  $lf = $null
  try {
    $lf = Get-Content -Raw -Path $lockfile | ConvertFrom-Json -AsHashtable
  } catch {
    Write-ErrorMessage "lockfile.json could not be parsed: $_"
    return $false
  }
  if ($null -eq $lf) {
    Write-ErrorMessage "lockfile.json could not be read"
    return $false
  }

  $errors = Invoke-LockfileEnforcement -Lockfile $lf `
    -InfoFn { param($m) Write-Message $m } `
    -WarnFn { param($m) Write-WarningMessage $m } `
    -ErrorFn { param($m) Write-ErrorMessage $m }

  if ($errors -gt 0) {
    Write-ErrorMessage "lockfile enforcement found $errors pinned section(s) with version drift"
    return $false
  }
  Write-Message "lockfile enforcement: all applicable pinned sections match"
  return $true
}
