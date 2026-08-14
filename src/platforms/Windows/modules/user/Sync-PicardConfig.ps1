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
    Mandatory: array of managed user records from Load-UserRegistry.ps1.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Sync-PicardConfig -Enabled:$true -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .EXAMPLE
    Sync-PicardConfig -Enabled:$false -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

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

  function Get-PicardDefaultPairsFromFile {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw "Picard defaults file was not found: $Path"
    }

    $pairs = New-Object 'System.Collections.Generic.List[object]'
    $section = ''

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
      $trimmed = $line.Trim()
      if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
        continue
      }

      if ($trimmed -match '^\[(.+)\]$') {
        $section = $Matches[1]
        continue
      }

      if ([string]::IsNullOrWhiteSpace($section)) {
        continue
      }

      $separator = $line.IndexOf('=')
      if ($separator -lt 1) {
        continue
      }

      $key = $line.Substring(0, $separator).Trim()
      if ([string]::IsNullOrWhiteSpace($key)) {
        continue
      }

      $value = $line.Substring($separator + 1)
      $pairs.Add([pscustomobject]@{
          Section = $section
          Key = $key
          Value = $value
        })
    }

    return @($pairs)
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
      New-Item -ItemType Directory -Path $parentDir -Force > $null
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
    $defaultsFilePath = Resolve-UserConfigFile -User $username -ConfigName 'picard' -RelativePath 'Picard.ini' -RepoRoot $RepoRoot
    $defaultPairs = Get-PicardDefaultPairsFromFile -Path $defaultsFilePath
    $defaultSettingNames = @(
      $defaultPairs |
        Where-Object { $_.Section -eq 'setting' } |
        ForEach-Object { $_.Key } |
        Sort-Object -Unique
    )
    $managedSettingNames = $defaultSettingNames

    $existingLines = @()
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $existingLines = @([System.IO.File]::ReadAllLines($configPath))
    }

    if ($Enabled) {
      $updatedLines = $existingLines

      foreach ($pair in $defaultPairs) {
        $updatedLines = _upsert_ini_key -Lines $updatedLines -Section $pair.Section -Key $pair.Key -Value $pair.Value
      }

      _write_ini_file -Path $configPath -Lines $updatedLines
      Write-NucleusInfo -CommandName 'Sync-PicardConfig' "Picard settings synced for $username."
      continue
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      Write-NucleusInfo -CommandName 'Sync-PicardConfig' "Picard settings cleanup complete for $username."
      continue
    }

    $cleanedLines = _remove_managed_ini_keys -Lines $existingLines -Section 'setting' -Keys $managedSettingNames
    _write_ini_file -Path $configPath -Lines $cleanedLines
    Write-NucleusInfo -CommandName 'Sync-PicardConfig' "Picard settings cleanup complete for $username."
  }
}
