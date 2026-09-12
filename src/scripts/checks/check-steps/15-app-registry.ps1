Register-Step -Id "app-registry" -Name "App auto-start registry validation" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $appJson = Join-Path $r "src\modules\apps.json"
  $appErrors = 0

  if (-not (Test-Path $appJson)) {
    Write-ErrorMessage "apps.json not found at $appJson"
    $appErrors++
  }
  else {
    $apps = Get-Content $appJson -Raw | ConvertFrom-Json -AsHashtable
    $validKinds = @('login-item', 'launchagent', 'xdg-desktop', 'run-key', 'startup-folder', 'system-extension')

    foreach ($appName in $apps.Keys) {
      if ($appName -like '$*') { continue }
      $entry = $apps[$appName]
      if ($entry -isnot [hashtable]) { continue }
      if (-not $entry.ContainsKey('hosts') -or $entry.hosts.Count -eq 0) { continue }

      foreach ($hostName in $entry.hosts.Keys) {
        $hEntry = $entry.hosts[$hostName]
        if ($hEntry -isnot [hashtable]) { continue }

        # Omitted hosts must have justification.
        $type = if ($hEntry.ContainsKey('type')) { $hEntry.type } else { 'missing' }
        if ($type -eq 'omitted') {
          $hasJust = $hEntry.ContainsKey('justification') -and -not [string]::IsNullOrEmpty($hEntry.justification)
          if (-not $hasJust) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' is omitted but missing justification"
            $appErrors++
          }
          continue
        }

        # autostartEnabled must be boolean.
        if ($entry.ContainsKey('autostartEnabled')) {
          $enabled = $entry.autostartEnabled
          if ($enabled -isnot [bool]) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' autostartEnabled must be boolean (got '$enabled')"
            $appErrors++
          }
        }

        # autostartDisableNative must be boolean.
        if ($hEntry.ContainsKey('autostartDisableNative')) {
          $disableNative = $hEntry.autostartDisableNative
          if ($disableNative -isnot [bool]) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' autostartDisableNative must be boolean (got '$disableNative')"
            $appErrors++
          }
        }

        # kind must be in the valid enum (if present).
        if ($hEntry.ContainsKey('kind')) {
          $kind = $hEntry.kind
          if ($kind -notin $validKinds) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' has invalid kind '$kind'"
            $appErrors++
          }
        }
      }
    }
  }

  if ($appErrors -gt 0) {
    Write-ErrorMessage "app registry validation failed with $appErrors error(s)"
    return $false
  }
  Write-Message "app registry validation passed."
  return $true
}
