Register-Step -Id "service-registry" -Number 14 -Name "Service registry validation" -Action {
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

  # Validate that service names in per-user services.json files exist in services.json.
  $usersRoot = Join-Path $r "src\users"
  if (Test-Path $usersRoot) {
    foreach ($servicesFile in Get-ChildItem -Path $usersRoot -Directory | ForEach-Object {
        $candidate = Join-Path $_.FullName 'services.json'
        if (Test-Path $candidate) { Get-Item $candidate }
      }) {
      $username = $servicesFile.Directory.Name
      if ($username -eq 'default') { continue }
      $userServices = Get-Content $servicesFile.FullName -Raw | ConvertFrom-Json -AsHashtable
      foreach ($svcKey in $userServices.Keys) {
        if ($svcKey -like '$*') { continue }
        $svcEntry = $userServices[$svcKey]
        if ($svcEntry -isnot [hashtable]) { continue }
        if ($svcEntry.ContainsKey('enable') -and -not $svc.ContainsKey($svcKey)) {
          Write-ErrorMessage "$($servicesFile.FullName): user '$username' references unknown service '$svcKey'"
          $svcErrors++
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
