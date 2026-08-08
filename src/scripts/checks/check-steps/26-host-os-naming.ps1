Register-Step -Id "host-os-naming" -Number 26 -Name "Host and OS naming validation" -Action {
  param($RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $errors = 0

  $servicesJson = Join-Path $r 'src\modules\services.json'
  $registryJson = Join-Path $r 'src\modules\host-platform-registry.json'
  $flakeNix = Join-Path $r 'src\flake.nix'
  $envCatalog = Join-Path $r 'src\modules\lib\env-catalog.nix'

  $svc = Get-Content $servicesJson -Raw | ConvertFrom-Json -AsHashtable
  foreach ($name in $svc.Keys) {
    if ($name -like '$*') { continue }
    $entry = $svc[$name]
    if ($entry -is [hashtable] -and $entry.ContainsKey('platforms')) {
      Write-ErrorMessage "services.json: '$name' uses legacy 'platforms' key — use 'hosts'"
      $errors++
    }
  }

  $registry = Get-Content $registryJson -Raw | ConvertFrom-Json -AsHashtable
  foreach ($hostName in $registry.hosts.Keys) {
    if ($registry.hosts[$hostName].ContainsKey('flags')) {
      Write-ErrorMessage "host-platform-registry.json: host '$hostName' must not contain flags"
      $errors++
    }
  }

  $flakeText = Get-Content $flakeNix -Raw
  if ($flakeText -notmatch 'darwinConfigurations\.MacBook') {
    Write-ErrorMessage 'flake.nix: darwinConfigurations.MacBook not found'
    $errors++
  }
  if ($flakeText -notmatch 'nixosConfigurations\.NixOS') {
    Write-ErrorMessage 'flake.nix: nixosConfigurations.NixOS not found'
    $errors++
  }

  $envText = Get-Content $envCatalog -Raw
  if ($envText -match 'values\.macOS') {
    Write-ErrorMessage 'env-catalog.nix: values.macOS found — use values.MacBook'
    $errors++
  }

  if ($errors -gt 0) {
    Write-ErrorMessage "host/OS naming validation failed with $errors error(s)"
    return $false
  }

  Write-Message 'host/OS naming validation passed'
  return $true
}
