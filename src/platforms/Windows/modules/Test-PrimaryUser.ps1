function Test-PrimaryUser {
  <#
  .SYNOPSIS
    Returns whether the current Windows user is the configured primary user.
  .PARAMETER PrimaryUsername
    Canonical primary username.
  .PARAMETER Quiet
    Suppress the skip warning when the username does not match.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername,

    [Parameter()]
    [switch]$Quiet
  )

  $currentUsername = [System.Environment]::UserName
  if ($currentUsername -eq $PrimaryUsername) {
    return $true
  }

  if (-not $Quiet) {
    Write-Output "$([System.Management.Automation.Psstyle]::Foreground.Yellow)Skipping secret materialization for non-primary user '$currentUsername'. Expected '$PrimaryUsername'."
  }

  return $false
}
