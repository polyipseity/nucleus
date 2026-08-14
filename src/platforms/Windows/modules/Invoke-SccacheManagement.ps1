<#
.SYNOPSIS
  sccache cache management helpers for nucleus gc workflows.

.DESCRIPTION
  Provides Clear-SccacheCache and Get-SccacheCacheDir. sccache has no --clear
  flag; local disk cache must be removed directly after stopping the server.
#>

function Get-SccacheCacheDir {
  <#
  .SYNOPSIS
    Returns the local sccache disk cache directory.
  #>
  [CmdletBinding()]
  param()

  if ($env:SCCACHE_DIR) {
    return $env:SCCACHE_DIR
  }

  return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Mozilla\sccache'
}

function Clear-SccacheCache {
  <#
  .SYNOPSIS
    Stops the sccache server and deletes local cache files.
  #>
  [CmdletBinding()]
  param()

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  $sccacheCmd = Get-Command -Name 'sccache' -ErrorAction SilentlyContinue
  if ($null -eq $sccacheCmd) {
    Write-NucleusWarning -CommandName 'sccache' 'sccache not installed; skipping sccache cache gc'
    return
  }

  Write-NucleusInfo -CommandName 'sccache' 'clearing cache'
  & $sccacheCmd.Source --stop-server 2>$null  # check-suppress:suppression_doc: server may not be running; stop is best-effort before cache removal.

  $cacheDir = Get-SccacheCacheDir
  if (Test-Path -LiteralPath $cacheDir -PathType Container) {
    Get-ChildItem -LiteralPath $cacheDir -Force | Remove-Item -Recurse -Force
  }
}
