function Sync-ObsidianConfig {
  <#
  .SYNOPSIS
    Applies the repository-managed Obsidian advanced settings for each managed user.

  .DESCRIPTION
    Merges a small repository-managed Obsidian settings subset into each
    user's live %APPDATA%\obsidian\obsidian.json file. The managed subset is
    intentionally defined in code instead of a standalone repo JSON file
    because Obsidian stores app-owned runtime state (such as vault metadata)
    in the same JSON document.

    This function therefore edits only the managed top-level keys and preserves
    all unmanaged keys unchanged. False removes only the managed keys so the
    app can fall back to its own defaults without losing vault registrations.

  .PARAMETER Enabled
    True applies the managed values. False removes only the managed Obsidian keys.

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Sync-ObsidianConfig -Enabled:$true -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .EXAMPLE
    Sync-ObsidianConfig -Enabled:$false -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

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

  function Copy-Hashtable {
    param(
      [Parameter(Mandatory = $true)]
      [hashtable]$Source
    )

    $copy = @{}
    foreach ($entry in $Source.GetEnumerator()) {
      $copy[$entry.Key] = $entry.Value
    }
    return $copy
  }

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

  function Read-ObsidianConfig {
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
      throw "Obsidian config '$Path' must be a JSON object at the top level."
    }

    return $parsed
  }

  function Get-ObsidianDesiredState {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Username,

      [Parameter(Mandatory = $true)]
      [string]$RepoRoot
    )

    $settingsPath = Resolve-UserConfigFile -User $Username -ConfigName 'obsidian' -RelativePath 'obsidian.json' -RepoRoot $RepoRoot
    $defaultSettings = ConvertTo-Hashtable -InputObject (Get-Content -Path $settingsPath -Raw | ConvertFrom-Json)
    if ($defaultSettings -isnot [hashtable]) {
      throw "Obsidian overlay config '$settingsPath' must be a JSON object at the top level."
    }

    return $defaultSettings
  }

  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory
    $configPath = Join-Path -Path $userHome -ChildPath 'AppData\Roaming\obsidian\obsidian.json'
    $managedSettings = Get-ObsidianDesiredState -Username $username -RepoRoot $RepoRoot
    $managedSettingNames = @($managedSettings.Keys | Sort-Object)

    if ($Enabled) {
      $existingConfig = Read-ObsidianConfig -Path $configPath
      foreach ($settingName in $managedSettingNames) {
        $existingConfig[$settingName] = $managedSettings[$settingName]
      }
      Write-Utf8Json -Path $configPath -Value $existingConfig
      Write-Output "$($PSStyle.Foreground.Green)Obsidian settings synced for $username.$($PSStyle.Reset)"
      continue
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      Write-Output "$($PSStyle.Foreground.Yellow)Obsidian settings cleanup complete for $username.$($PSStyle.Reset)"
      continue
    }

    $existingConfig = Read-ObsidianConfig -Path $configPath
    foreach ($settingName in $managedSettingNames) {
      $null = $existingConfig.Remove($settingName)  # check-suppress:suppression_doc: Remove returns boolean, discarded
    }

    if ($existingConfig.Count -eq 0) {
      Remove-Item -LiteralPath $configPath -Force
    } else {
      Write-Utf8Json -Path $configPath -Value $existingConfig
    }

    Write-Output "$($PSStyle.Foreground.Yellow)Obsidian settings cleanup complete for $username.$($PSStyle.Reset)"
  }
}
