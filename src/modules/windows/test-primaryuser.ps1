# modules/windows/test-primaryuser.ps1 — Primary-user guard helper.
#
# Keeps secret and user-scoped parity mutations restricted to the configured
# primary account.

function Test-PrimaryUser {
  <#
  .SYNOPSIS
    Returns whether the current Windows user is the configured primary user.

  .DESCRIPTION
    Compares the current interactive username against $PrimaryUsername.
    Secret materialization must only run for this primary user; non-primary
    users are always skipped.

  .PARAMETER PrimaryUsername
    Canonical primary username (for example: 'polyipseity').

  .PARAMETER Quiet
    Suppress the skip warning when the username does not match.

  .OUTPUTS
    [bool]  True when current user matches $PrimaryUsername.
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
