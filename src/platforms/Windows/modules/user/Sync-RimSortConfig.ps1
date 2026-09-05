function Sync-RimSortConfig {
  <#
  .SYNOPSIS
    Applies the repository-managed RimSort instance settings for each managed user.

  .DESCRIPTION
    Merges a small repository-managed RimSort settings subset into each
    user's live %LOCALAPPDATA%\RimSort\settings.json file. The managed
    subset contains per-instance paths (game folder, config folder, local
    mods, workshop folder) and Steam integration flags that are resolved
    from the per-host overlay JSON in the repository.

    This function ensures the instances.Default nesting exists before
    merging managed keys into it, preserving all unmanaged keys (theme,
    sorting, window state, SteamCMD settings) unchanged.

    False removes only the managed keys so the app can fall back to its
    own defaults or autodetect without losing other instance data.

  .PARAMETER Enabled
    True applies the managed values. False removes only the managed keys.

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Sync-RimSortConfig -Enabled:$true -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .EXAMPLE
    Sync-RimSortConfig -Enabled:$false -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [object[]]$Users,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  function ConvertTo-Hashtable {
    param(
      [Parameter(Mandatory = $false)]
      [AllowNull()]
      [object]$InputObject
    )

    if ($null -eq $InputObject) {
      return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
      $hash = @{}
      foreach ($key in $InputObject.Keys) {
        $hash[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
      }
      return $hash
    }

    if ($InputObject -is [pscustomobject]) {
      $hash = @{}
      foreach ($property in $InputObject.PSObject.Properties) {
        $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
      }
      return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
      return @($InputObject | ForEach-Object { ConvertTo-Hashtable -InputObject $_ })
    }

    return $InputObject
  }

  function Write-Utf8Json {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path,

      [Parameter(Mandatory = $true)]
      [hashtable]$Value
    )

    $parentDir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
      New-Item -ItemType Directory -Path $parentDir -Force > $null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $Value | ConvertTo-Json -Compress -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
  }

  function Read-RimSortConfig {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      return @{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return @{}
    }

    $parsed = ConvertTo-Hashtable -InputObject ($raw | ConvertFrom-Json)
    if ($parsed -isnot [hashtable]) {
      throw "RimSort config '$Path' must be a JSON object at the top level."
    }

    return $parsed
  }

  function Get-RimSortDesiredState {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Username,

      [Parameter(Mandatory = $true)]
      [string]$RepoRoot
    )

    $settingsPath = Resolve-UserConfigFile -User $Username -ConfigName 'rimsort' -RelativePath 'rimsort.json' -RepoRoot $RepoRoot
    $defaultSettings = ConvertTo-Hashtable -InputObject (Get-Content -Path $settingsPath -Raw | ConvertFrom-Json)
    if ($defaultSettings -isnot [hashtable]) {
      throw "RimSort overlay config '$settingsPath' must be a JSON object at the top level."
    }

    return $defaultSettings
  }

  # Managed keys that converge on every activation.
  $managedKeys = @('game_folder', 'config_folder', 'local_folder', 'workshop_folder', 'steam_client_integration', 'launch_via_steam_protocol', 'steamcmd_install_path')

  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory
    $configPath = Join-Path -Path $userHome -ChildPath 'AppData\Local\RimSort\settings.json'
    $managedSettings = Get-RimSortDesiredState -Username $username -RepoRoot $RepoRoot

    if ($Enabled) {
      $existingConfig = Read-RimSortConfig -Path $configPath

      # Ensure the instances and Default nesting exists before merging.
      if (-not $existingConfig.ContainsKey('instances') -or $null -eq $existingConfig['instances']) {
        $existingConfig['instances'] = @{}
      }
      $instances = $existingConfig['instances']
      if ($instances -isnot [hashtable]) {
        $instances = ConvertTo-Hashtable -InputObject $instances
        $existingConfig['instances'] = $instances
      }
      if (-not $instances.ContainsKey('Default') -or $null -eq $instances['Default']) {
        $instances['Default'] = @{}
      }
      $defaultInstance = $instances['Default']
      if ($defaultInstance -isnot [hashtable]) {
        $defaultInstance = ConvertTo-Hashtable -InputObject $defaultInstance
        $instances['Default'] = $defaultInstance
      }

      # Merge managed keys into instances.Default.
      $managedDefault = @{}
      if ($managedSettings.ContainsKey('instances')) {
        $managedInstances = $managedSettings['instances']
        if ($managedInstances -is [hashtable] -and $managedInstances.ContainsKey('Default')) {
          $managedDefault = $managedInstances['Default']
          if ($managedDefault -isnot [hashtable]) {
            $managedDefault = ConvertTo-Hashtable -InputObject $managedDefault
          }
        }
      }

      foreach ($key in $managedKeys) {
        if ($managedDefault.ContainsKey($key)) {
          $defaultInstance[$key] = $managedDefault[$key]
        }
      }

      # Converge top-level current_instance if present in managed settings.
      if ($managedSettings.ContainsKey('current_instance')) {
        $existingConfig['current_instance'] = $managedSettings['current_instance']
      }

      Write-Utf8Json -Path $configPath -Value $existingConfig
      Write-NucleusInfo -CommandName 'Sync-RimSortConfig' "RimSort settings synced for $username."
      continue
    }

    # Cleanup path: remove only managed keys from instances.Default.
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      Write-NucleusInfo -CommandName 'Sync-RimSortConfig' "RimSort settings cleanup complete for $username."
      continue
    }

    $existingConfig = Read-RimSortConfig -Path $configPath
    if ($existingConfig.ContainsKey('instances') -and $existingConfig['instances'] -is [hashtable]) {
      $instances = $existingConfig['instances']
      if ($instances.ContainsKey('Default') -and $instances['Default'] -is [hashtable]) {
        $defaultInstance = $instances['Default']
        foreach ($key in $managedKeys) {
          if ($defaultInstance.ContainsKey($key)) {
            $null = $defaultInstance.Remove($key)  # check-suppress:suppression_doc: Remove returns boolean, discarded
          }
        }
        # Remove empty Default instance if no keys remain.
        if ($defaultInstance.Count -eq 0) {
          $null = $instances.Remove('Default')  # check-suppress:suppression_doc: Remove returns boolean, discarded
        }
      }
      # Remove empty instances if no instances remain.
      if ($instances.Count -eq 0) {
        $null = $existingConfig.Remove('instances')  # check-suppress:suppression_doc: Remove returns boolean, discarded
      }
    }

    if ($existingConfig.Count -eq 0) {
      Remove-Item -LiteralPath $configPath -Force
    } else {
      Write-Utf8Json -Path $configPath -Value $existingConfig
    }

    Write-NucleusInfo -CommandName 'Sync-RimSortConfig' "RimSort settings cleanup complete for $username."
  }
}
