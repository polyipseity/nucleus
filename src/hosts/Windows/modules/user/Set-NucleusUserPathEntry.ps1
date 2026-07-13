<#
.SYNOPSIS
  Add a directory to the user-level PATH if not already present, with
  dedup, broadcast, and logging.
.DESCRIPTION
  Checks both the User registry PATH and the process-level $env:PATH.  If
  $Directory is not already in the User PATH, prepends it and broadcasts
  WM_SETTINGCHANGE so running processes pick up the change.  Also updates
  the session-level $env:PATH so the directory is immediately available.

  This replaces manual PATH blocks that use wildcard matching (-notlike),
  which can false-negative when $Directory contains regex-special characters.

  Parameters must be named.
.EXAMPLE
  Set-NucleusUserPathEntry -Directory "C:\tools\bin" -Name "tools"

  Adds C:\tools\bin to user PATH (if not already there) and logs with
  the prefix "tools-setup:".
.EXAMPLE
  Set-NucleusUserPathEntry -Directory "C:\tools\bin"

  Same as above with no script-prefix log label.
.NOTES
  Cross-reference: docs/env-variable-registry.md
  Requires Send-NucleusEnvChangeNotification to be dot-sourced first.
#>
function Set-NucleusUserPathEntry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [Parameter()]
    [string]$Name = ""
  )

  $prefix = if ($Name) { "$Name`: " } else { "" }
  $changed = $false

  # Check and update User-scope PATH using array split (not wildcard).
  $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
  $userPathEntries = if ($userPath) { $userPath -split ";" } else { @() }
  if ($Directory -notin $userPathEntries) {
    $newPath = if ($userPath) { "$Directory;$userPath" } else { $Directory }
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Output "${prefix}added $Directory to user PATH"
    $changed = $true
  }

  # Also update session-level PATH so the binary is immediately available.
  $sessionPathEntries = if ($env:PATH) { $env:PATH -split ";" } else { @() }
  if ($Directory -notin $sessionPathEntries) {
    $env:PATH = "$Directory;$env:PATH"
  }

  # Broadcast change notification if we actually modified the User PATH.
  if ($changed) {
    Send-NucleusEnvChangeNotification
  }

  return $changed
}
