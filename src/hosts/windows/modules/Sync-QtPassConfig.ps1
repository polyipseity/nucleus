# modules/windows/sync-qtpass-config.ps1 — Declarative QtPass user settings.

function Sync-QtPassConfig {
  <#
  .SYNOPSIS
    Applies the repository-managed QtPass Settings/Template tab values for each managed user.

  .DESCRIPTION
    Reads the shared screenshot-backed defaults from the JSON file in
    src\modules\configs\qtpass\settings.json, merges any per-user overrides
    declared in src\hosts\windows\users.json, then writes the resulting
    QSettings values into each user's QtPass registry hive.

    When a managed user's profile hive is not already loaded under HKEY_USERS,
    this function temporarily loads NTUSER.DAT, writes the managed values, and
    unloads the hive again. False removes the managed QtPass values so the app
    falls back to its own defaults and any future manual edits.

  .PARAMETER Enabled
    True applies the managed values. False removes the managed QtPass values.

  .PARAMETER SettingsPath
    Absolute path to the shared QtPass JSON settings file. Mandatory: callers
    must pass the path explicitly so they are aware of the cross-platform
    source of truth being applied.

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1. Each
    user can optionally include qtpass.settings overrides.

  .EXAMPLE
    Sync-QtPassConfig -Enabled:$true -SettingsPath 'C:\Users\admin\nucleus\src\modules\configs\qtpass\settings.json' -Users $userRegistry.users

  .EXAMPLE
    Sync-QtPassConfig -Enabled:$false -SettingsPath 'C:\Users\admin\nucleus\src\modules\configs\qtpass\settings.json' -Users $userRegistry.users
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [string]$SettingsPath,

    [Parameter(Mandatory = $true)]
    [object[]]$Users
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

  function Get-QtPassDesiredState {
    param(
      [Parameter(Mandatory = $true)]
      [hashtable]$DefaultSettings,

      [Parameter(Mandatory = $true)]
      [object]$UserRecord
    )

    $effectiveSettings = Copy-Hashtable -Source $DefaultSettings
    $userQtPass = ConvertTo-Hashtable -InputObject $UserRecord.qtpass

    if ($null -ne $userQtPass -and $userQtPass.ContainsKey('settings')) {
      $userOverrides = ConvertTo-Hashtable -InputObject $userQtPass.settings
      if ($null -ne $userOverrides) {
        foreach ($entry in $userOverrides.GetEnumerator()) {
          $effectiveSettings[$entry.Key] = $entry.Value
        }
      }
    }

    return $effectiveSettings
  }

  function Get-QtPassRegistryHive {
    param(
      [Parameter(Mandatory = $true)]
      [string]$UserHome,

      [Parameter(Mandatory = $true)]
      [string]$Username
    )

    $userProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.LocalPath -eq $UserHome } | Select-Object -First 1
    if ($null -eq $userProfile -or [string]::IsNullOrWhiteSpace($userProfile.SID)) {
      throw "Unable to resolve a user profile SID for '$Username' at '$UserHome'."
    }

    $sidHivePath = "Registry::HKEY_USERS\$($userProfile.SID)"
    if (Test-Path -LiteralPath $sidHivePath) {
      return @{
        HiveRoot = $sidHivePath
      }
    }

    $ntUserDatPath = Join-Path -Path $UserHome -ChildPath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserDatPath -PathType Leaf)) {
      throw "Unable to load QtPass settings for '$Username': user hive file not found at '$ntUserDatPath'."
    }

    $temporaryHiveName = "NUCLEUS_QTPASS_$Username`_$PID"
    $loadOutput = & reg.exe load "HKU\$temporaryHiveName" "$ntUserDatPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to load registry hive for '$Username': $($loadOutput -join ' ')"
    }

    return @{
      HiveRoot = "Registry::HKEY_USERS\$temporaryHiveName"
      TemporaryHive = $temporaryHiveName
    }
  }

  function Invoke-QtPassManagedCleanup {
    param(
      [Parameter(Mandatory = $true)]
      [string]$QtPassRegistryPath,

      [Parameter(Mandatory = $true)]
      [string[]]$SettingNames
    )

    if (-not (Test-Path -LiteralPath $QtPassRegistryPath)) {
      return
    }

    foreach ($settingName in $SettingNames) {
      Remove-ItemProperty -LiteralPath $QtPassRegistryPath -Name $settingName -ErrorAction SilentlyContinue
    }

    $remainingPropertyNames = @((Get-Item -LiteralPath $QtPassRegistryPath).Property)
    if ($remainingPropertyNames.Count -eq 0) {
      Remove-Item -LiteralPath $QtPassRegistryPath -Force
    }
  }

  if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    throw "QtPass settings file not found: $SettingsPath"
  }

  $defaultSettings = ConvertTo-Hashtable -InputObject (Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json)

  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory
    $effectiveSettings = Get-QtPassDesiredState -DefaultSettings $defaultSettings -UserRecord $userRecord
    $managedSettingNames = @($effectiveSettings.Keys | Sort-Object)
    $hiveInfo = Get-QtPassRegistryHive -UserHome $userHome -Username $username
    $qtPassRegistryPath = Join-Path -Path $hiveInfo.HiveRoot -ChildPath 'Software\IJHack\QtPass'

    try {
      if ($Enabled) {
        New-Item -Path $qtPassRegistryPath -Force | Out-Null

        foreach ($settingName in $managedSettingNames) {
          $settingValue = $effectiveSettings[$settingName]
          if ($settingValue -is [bool]) {
            New-ItemProperty -LiteralPath $qtPassRegistryPath -Name $settingName -PropertyType DWord -Value ([int]$settingValue) -Force | Out-Null
            continue
          }

          if ($settingValue -is [int] -or $settingValue -is [long]) {
            New-ItemProperty -LiteralPath $qtPassRegistryPath -Name $settingName -PropertyType DWord -Value ([int]$settingValue) -Force | Out-Null
            continue
          }

          if ($settingValue -is [string]) {
            New-ItemProperty -LiteralPath $qtPassRegistryPath -Name $settingName -PropertyType String -Value $settingValue -Force | Out-Null
            continue
          }

          throw "QtPass setting '$settingName' for '$username' has unsupported type '$($settingValue.GetType().FullName)'."
        }

        Write-Output "$($PSStyle.Foreground.Green)QtPass settings synced for $username.$($PSStyle.Reset)"
      }
      else {
        Invoke-QtPassManagedCleanup -QtPassRegistryPath $qtPassRegistryPath -SettingNames $managedSettingNames
        Write-Output "$($PSStyle.Foreground.Yellow)QtPass settings cleanup complete for $username.$($PSStyle.Reset)"
      }
    }
    finally {
      if ($hiveInfo.ContainsKey('TemporaryHive')) {
        $unloadOutput = & reg.exe unload "HKU\$($hiveInfo.TemporaryHive)" 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to unload temporary QtPass registry hive '$($hiveInfo.TemporaryHive)': $($unloadOutput -join ' ')"
        }
      }
    }
  }
}
