<#
.SYNOPSIS
  Create log subdirectories for all nucleus services from services.json.

.DESCRIPTION
  Reads the services registry (services.json) and creates all log subdirectories
  declared in each service's logging.dirs block under the system and user log
  roots.  This centralizes log directory creation so individual Sync-*Service
  modules don't need their own New-Item calls.

  The function uses Get-NucleusSystemLogDir and Get-NucleusLogDir to resolve
  the platform-specific log roots, and then creates each subdirectory declared
  in dirs.system and dirs.user for every non-omitted service.

.EXAMPLE
  Invoke-EnsureLogDirs -ServicesJson "C:\nucleus\src\modules\services.json"
#>
function Invoke-EnsureLogDirs {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ServicesJson
  )

  $svc = Get-Content -Raw -LiteralPath $ServicesJson | ConvertFrom-Json
  $systemLogDir = Get-NucleusSystemLogDir
  $userLogDir = Get-NucleusLogDir

  foreach ($entry in $svc.PSObject.Properties) {
    if ($entry.Value.PSObject.TypeNames -match 'Deserialized\..*Hashtable' -or $entry.Value -isnot [PSCustomObject]) {
      continue
    }
    $dirs = $entry.Value.logging.dirs
    if (-not $dirs) { continue }

    # System subdirs (e.g. %ProgramData%\nucleus\logs\camilladsp)
    if ($dirs.system -and $dirs.system.Count -gt 0) {
      foreach ($subdir in $dirs.system) {
        $path = Join-Path -Path $systemLogDir -ChildPath $subdir
        $null = New-Item -Path $path -ItemType Directory -Force
      }
    }

    # User subdirs (e.g. %LOCALAPPDATA%\nucleus\logs\camilladsp)
    if ($dirs.user -and $dirs.user.Count -gt 0) {
      foreach ($subdir in $dirs.user) {
        $path = Join-Path -Path $userLogDir -ChildPath $subdir
        $null = New-Item -Path $path -ItemType Directory -Force
      }
    }
  }
}

# Keep module-level state out of global scope: only export the function.
Export-ModuleMember -Function Invoke-EnsureLogDirs
