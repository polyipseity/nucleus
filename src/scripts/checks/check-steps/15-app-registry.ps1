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
    # The valid kinds come from the schema enum, so this check cannot drift from
    # the schema the way a second hardcoded list would.
    $appSchema = Join-Path $r "src\modules\apps.schema.json"
    $validKinds = (Get-Content $appSchema -Raw | ConvertFrom-Json).definitions.autostartKind.enum

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

        # autostartEnabled is required for every kind we launch and forbidden for
        # 'manual' — nothing is launched, so a toggle there would be a lie.
        $entryKind = if ($hEntry.ContainsKey('kind')) { $hEntry.kind } else { 'missing' }
        $enabled = if ($hEntry.ContainsKey('autostartEnabled')) { $hEntry.autostartEnabled } else { $null }
        if ($entryKind -eq 'manual') {
          if ($null -ne $enabled) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' kind 'manual' must not set autostartEnabled"
            $appErrors++
          }
        }
        elseif ($enabled -isnot [bool]) {
          Write-ErrorMessage "apps.json: '$appName' host '$hostName' autostartEnabled must be boolean (got '$enabled')"
          $appErrors++
        }

        # kind must be in the valid enum (if present), and a platform-prefixed
        # kind must match its host platform.
        if ($entryKind -ne 'missing') {
          $kind = $entryKind
          if ($kind -notin $validKinds) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' has invalid kind '$kind'"
            $appErrors++
          }

          $kindPlatform = switch -Wildcard ($kind) {
            'macos-*' { 'macOS' }
            'nixos-*' { 'NixOS' }
            'windows-*' { 'Windows' }
            default { '' }
          }
          $entryPlatform = if ($hEntry.ContainsKey('platform')) { $hEntry.platform } else { 'missing' }
          if ($kindPlatform -and $kindPlatform -ne $entryPlatform) {
            Write-ErrorMessage "apps.json: '$appName' host '$hostName' kind '$kind' is $kindPlatform-only but the host platform is '$entryPlatform'"
            $appErrors++
          }

          # Kinds no script can converge still need approvalInstructions: that
          # text is the only guidance the report prints.
          if ($kind -in @('macos-system-extension', 'manual')) {
            $hasApproval = $hEntry.ContainsKey('approvalInstructions') -and -not [string]::IsNullOrEmpty($hEntry.approvalInstructions)
            if (-not $hasApproval) {
              Write-ErrorMessage "apps.json: '$appName' host '$hostName' kind '$kind' requires approvalInstructions"
              $appErrors++
            }
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
