Register-Step -Number 14 -Name "Service registry validation" -Action {
  param($RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $svcJson = Join-Path $r "src\modules\services.json"
  $svcErrors = 0

  if (-not (Test-Path $svcJson)) {
    Write-ErrorMessage "services.json not found at $svcJson"
    return $false
  }

  $svc = Get-Content $svcJson -Raw | ConvertFrom-Json -AsHashtable

  # Validate each service entry.
  foreach ($svcName in $svc.Keys) {
    if ($svcName -like '$*') { continue }
    $entry = $svc[$svcName]
    if ($entry -isnot [hashtable]) { continue }
    if (-not $entry.ContainsKey('displayName') -or [string]::IsNullOrEmpty($entry.displayName)) {
      Write-ErrorMessage "services.json: '$svcName' missing displayName"
      $svcErrors++
    }
    if (-not $entry.ContainsKey('platforms') -or $entry.platforms.Count -eq 0) {
      Write-ErrorMessage "services.json: '$svcName' missing or empty platforms"
      $svcErrors++
    } else {
      foreach ($plat in $entry.platforms.Keys) {
        $pEntry = $entry.platforms[$plat]
        $type = $pEntry.type
        if ($type -notin @('launchctl', 'systemctl', 'native', 'schtask', 'omitted')) {
          Write-ErrorMessage "services.json: '$svcName' platform '$plat' has invalid type '$type'"
          $svcErrors++
        }
        $hasRequired = switch ($type) {
          'launchctl' { -not [string]::IsNullOrEmpty($pEntry.service) }
          'systemctl' { -not [string]::IsNullOrEmpty($pEntry.service) }
          'native' { -not [string]::IsNullOrEmpty($pEntry.service) }
          'schtask' { -not [string]::IsNullOrEmpty($pEntry.taskPath) }
          'omitted' { -not [string]::IsNullOrEmpty($pEntry.justification) }
          default { $false }
        }
        if (-not $hasRequired) {
          Write-ErrorMessage "services.json: '$svcName' platform '$plat' missing required fields for type '$type'"
          $svcErrors++
        }
      }
    }
  }

  # Validate user-scoped platform entries have justification.
  foreach ($svcName in $svc.Keys) {
    if ($svcName -like '$*') { continue }
    $entry = $svc[$svcName]
    if ($entry -isnot [hashtable]) { continue }
    if ($entry.ContainsKey('platforms')) {
      foreach ($plat in $entry.platforms.Keys) {
        $pEntry = $entry.platforms[$plat]
        $domainScope = if ($pEntry.ContainsKey('domain')) { $pEntry.domain } elseif ($pEntry.ContainsKey('scope')) { $pEntry.scope } else { $null }
        $hasJustification = $pEntry.ContainsKey('justification') -and -not [string]::IsNullOrEmpty($pEntry.justification)
        if ($domainScope -eq 'user' -and -not $hasJustification) {
          Write-ErrorMessage "services.json: '$svcName' platform '$plat' is user-scoped but missing justification"
          $svcErrors++
        }
      }
    }
  }

  # Validate that service names in users.json services blocks exist in services.json.
  $usersJson = Join-Path $r "src\modules\users.json"
  if (Test-Path $usersJson) {
    $users = Get-Content $usersJson -Raw | ConvertFrom-Json -AsHashtable
    foreach ($username in $users.Keys) {
      if ($username -like '$*') { continue }
      $userEntry = $users[$username]
      if ($userEntry.ContainsKey('services')) {
        foreach ($svcKey in $userEntry.services.Keys) {
          if (-not $svc.ContainsKey($svcKey)) {
            Write-ErrorMessage "${usersJson}: user '$username' references unknown service '$svcKey'"
            $svcErrors++
          }
        }
      }
    }
  }

  # Windows users.json
  $winUsersJson = Join-Path $r "src\hosts\Windows\users.json"
  if (Test-Path $winUsersJson) {
    $winUsers = (Get-Content $winUsersJson -Raw | ConvertFrom-Json -AsHashtable).users
    if ($winUsers) {
      foreach ($username in $winUsers.Keys) {
        $userEntry = $winUsers[$username]
        if ($userEntry.ContainsKey('services')) {
          foreach ($svcKey in $userEntry.services.Keys) {
            if (-not $svc.ContainsKey($svcKey)) {
              Write-ErrorMessage "${winUsersJson}: user '$username' references unknown service '$svcKey'"
              $svcErrors++
            }
          }
        }
      }
    }
  }

  if ($svcErrors -gt 0) {
    Write-ErrorMessage "services.json validation failed with $svcErrors error(s)"
    return $false
  }

  Write-Message "services.json validation passed"
  return $true
}
