# modules/Windows/Sync-PicardConfig.ps1 — Declarative Picard INI settings convergence.

function Sync-PicardConfig {
  <#
  .SYNOPSIS
    Applies repository-managed MusicBrainz Picard settings using native Picard.ini merge-overwrite.

  .DESCRIPTION
    Converges a managed subset of Picard INI keys into each managed user's
    %APPDATA%\MusicBrainz\Picard.ini without symlinks or hardlinks.

    The function updates only managed keys under [setting] and preserves all
    unmanaged keys/sections so user-private tokens or plugin values remain
    intact. If the INI file does not exist, it is created.

    When disabled, only managed keys are removed from [setting]; unmanaged
    content is preserved.

  .PARAMETER Enabled
    True applies managed values. False removes only managed Picard keys.

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1. Each
    user can optionally include picard.settings overrides.

  .EXAMPLE
    Sync-PicardConfig -Enabled:$true -Users $userRegistry.users

  .EXAMPLE
    Sync-PicardConfig -Enabled:$false -Users $userRegistry.users
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [object[]]$Users
  )

  function ConvertTo-PlainObject {
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
        $hash[$key] = ConvertTo-PlainObject -InputObject $InputObject[$key]
      }
      return $hash
    }

    if ($InputObject -is [pscustomobject]) {
      $hash = @{}
      foreach ($property in $InputObject.PSObject.Properties) {
        $hash[$property.Name] = ConvertTo-PlainObject -InputObject $property.Value
      }
      return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
      return @($InputObject | ForEach-Object { ConvertTo-PlainObject -InputObject $_ })
    }

    return $InputObject
  }

  function ConvertTo-PicardIniValue {
    param(
      [Parameter(Mandatory = $true)]
      [AllowNull()]
      [object]$Value,

      [Parameter(Mandatory = $true)]
      [string]$KeyName
    )

    if ($null -eq $Value) {
      throw "Picard setting '$KeyName' cannot be null."
    }

    if ($Value -is [bool]) {
      return (if ($Value) { 'true' } else { 'false' })
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [single]) {
      return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [string]) {
      return $Value
    }

    throw "Picard setting '$KeyName' has unsupported type '$($Value.GetType().FullName)'."
  }

  function Get-PicardDesiredState {
    param(
      [Parameter(Mandatory = $true)]
      [object]$UserRecord
    )

    # Shared cross-host defaults from Picard's native [setting] section.
    $effectiveSettings = @{
      completeness_ignore_data = $false
      completeness_ignore_pregap = $false
      release_ars = $true
    }

    $userPicard = ConvertTo-PlainObject -InputObject $UserRecord.picard
    if ($null -ne $userPicard -and $userPicard.ContainsKey('settings')) {
      $userOverrides = ConvertTo-PlainObject -InputObject $userPicard.settings
      if ($null -ne $userOverrides) {
        foreach ($entry in $userOverrides.GetEnumerator()) {
          $effectiveSettings[$entry.Key] = $entry.Value
        }
      }
    }

    return $effectiveSettings
  }

  function _write_ini_file {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path,

      [Parameter(Mandatory = $true)]
      [string[]]$Lines
    )

    $parentDir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
      New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
  }

  function _upsert_ini_key {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Lines,

      [Parameter(Mandatory = $true)]
      [string]$Section,

      [Parameter(Mandatory = $true)]
      [string]$Key,

      [Parameter(Mandatory = $true)]
      [string]$Value
    )

    $sectionHeader = "[$Section]"
    $sectionPattern = '^\[(.+)\]\s*$'
    $keyPattern = "^\s*$([Regex]::Escape($Key))\s*="

    $result = New-Object System.Collections.Generic.List[string]
    $sectionFound = $false
    $inTargetSection = $false
    $keyWritten = $false

    foreach ($line in $Lines) {
      if ($line -match $sectionPattern) {
        if ($inTargetSection -and -not $keyWritten) {
          $result.Add("$Key=$Value")
          $keyWritten = $true
        }

        $inTargetSection = $false
        if ($line.Trim() -eq $sectionHeader) {
          $sectionFound = $true
          $inTargetSection = $true
        }

        $result.Add($line)
        continue
      }

      if ($inTargetSection -and $line -match $keyPattern) {
        if (-not $keyWritten) {
          $result.Add("$Key=$Value")
          $keyWritten = $true
        }
        continue
      }

      $result.Add($line)
    }

    if (-not $sectionFound) {
      if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') {
        $result.Add('')
      }
      $result.Add($sectionHeader)
      $result.Add("$Key=$Value")
      return @($result)
    }

    if ($inTargetSection -and -not $keyWritten) {
      $result.Add("$Key=$Value")
    }

    return @($result)
  }

  function _remove_managed_ini_keys {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Lines,

      [Parameter(Mandatory = $true)]
      [string]$Section,

      [Parameter(Mandatory = $true)]
      [string[]]$Keys
    )

    $sectionPattern = '^\[(.+)\]\s*$'
    $result = New-Object System.Collections.Generic.List[string]
    $inTargetSection = $false

    foreach ($line in $Lines) {
      if ($line -match $sectionPattern) {
        $inTargetSection = ($Matches[1] -eq $Section)
        $result.Add($line)
        continue
      }

      if ($inTargetSection) {
        $isManagedKey = $false
        foreach ($key in $Keys) {
          $keyPattern = "^\s*$([Regex]::Escape($key))\s*="
          if ($line -match $keyPattern) {
            $isManagedKey = $true
            break
          }
        }

        if ($isManagedKey) {
          continue
        }
      }

      $result.Add($line)
    }

    return @($result)
  }

  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory
    $configPath = Join-Path -Path $userHome -ChildPath 'AppData\Roaming\MusicBrainz\Picard.ini'

    $managedSettings = Get-PicardDesiredState -UserRecord $userRecord
    $managedSettingNames = @($managedSettings.Keys | Sort-Object)

    $existingLines = @()
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $existingLines = @([System.IO.File]::ReadAllLines($configPath))
    }

    if ($Enabled) {
      $updatedLines = $existingLines
      foreach ($settingName in $managedSettingNames) {
        $settingValue = ConvertTo-PicardIniValue -Value $managedSettings[$settingName] -KeyName $settingName
        $updatedLines = _upsert_ini_key -Lines $updatedLines -Section 'setting' -Key $settingName -Value $settingValue
      }

      _write_ini_file -Path $configPath -Lines $updatedLines
      Write-Output "$($PSStyle.Foreground.Green)Picard settings synced for $username.$($PSStyle.Reset)"
      continue
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      Write-Output "$($PSStyle.Foreground.Yellow)Picard settings cleanup complete for $username.$($PSStyle.Reset)"
      continue
    }

    $cleanedLines = _remove_managed_ini_keys -Lines $existingLines -Section 'setting' -Keys $managedSettingNames
    _write_ini_file -Path $configPath -Lines $cleanedLines
    Write-Output "$($PSStyle.Foreground.Yellow)Picard settings cleanup complete for $username.$($PSStyle.Reset)"
  }
}
