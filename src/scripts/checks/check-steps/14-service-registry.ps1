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
    if (-not $entry.ContainsKey('hosts') -or $entry.hosts.Count -eq 0) {
      Write-ErrorMessage "services.json: '$svcName' missing or empty hosts"
      $svcErrors++
    } else {
      foreach ($hostName in $entry.hosts.Keys) {
        $hEntry = $entry.hosts[$hostName]
        $type = $hEntry.type
        if ($type -notin @('launchctl', 'systemctl', 'native', 'schtask', 'omitted')) {
          Write-ErrorMessage "services.json: '$svcName' host '$hostName' has invalid type '$type'"
          $svcErrors++
        }
        if ($hEntry.platform -notin @('macOS', 'NixOS', 'Windows')) {
          Write-ErrorMessage "services.json: '$svcName' host '$hostName' has invalid platform '$($hEntry.platform)'"
          $svcErrors++
        }
        $hasRequired = switch ($type) {
          'launchctl' { -not [string]::IsNullOrEmpty($hEntry.service) }
          'systemctl' { -not [string]::IsNullOrEmpty($hEntry.service) }
          'native' { -not [string]::IsNullOrEmpty($hEntry.service) }
          'schtask' { -not [string]::IsNullOrEmpty($hEntry.taskPath) }
          'omitted' { -not [string]::IsNullOrEmpty($hEntry.justification) }
          default { $false }
        }
        if (-not $hasRequired) {
          Write-ErrorMessage "services.json: '$svcName' host '$hostName' missing required fields for type '$type'"
          $svcErrors++
        }
      }
    }
  }

  # Validate user-scoped host entries have justification.
  foreach ($svcName in $svc.Keys) {
    if ($svcName -like '$*') { continue }
    $entry = $svc[$svcName]
    if ($entry -isnot [hashtable]) { continue }
    if ($entry.ContainsKey('hosts')) {
      foreach ($hostName in $entry.hosts.Keys) {
        $hEntry = $entry.hosts[$hostName]
        $domainScope = if ($hEntry.ContainsKey('domain')) { $hEntry.domain } elseif ($hEntry.ContainsKey('scope')) { $hEntry.scope } else { $null }
        $hasJustification = $hEntry.ContainsKey('justification') -and -not [string]::IsNullOrEmpty($hEntry.justification)
        if ($domainScope -eq 'user' -and -not $hasJustification) {
          Write-ErrorMessage "services.json: '$svcName' host '$hostName' is user-scoped but missing justification"
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
