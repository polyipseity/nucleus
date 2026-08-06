<#
.SYNOPSIS
  Shared config deployment helpers for Windows. Provides cmdlet-style functions
  matching the Nix config-utils.nix contract.

.DESCRIPTION
  Every config in src/modules/configs/ should use these functions to ensure
  consistent deployment semantics. See .agents/instructions/app-config-policy.instructions.md
  for the priority ordering and "why not #1" comment rule.

  These functions use Developer-Mode symlinks (available through
  Microsoft.Windows.Settings/DeveloperMode in system.dsc.yml).

  Each function returns an object with .Changed ($true/$false) and .Message so
  callers can log uniformly.
#>

function Deploy-WritableSymlink {
  <#
  .SYNOPSIS
    Method 1 (default) — creates a bidirectional writable symlink.
  .PARAMETER Name
    Unique identifier for logging.
  .PARAMETER RepoRoot
    Absolute path to the repository root ($env:NUCLEUS_REPO_ROOT).
  .PARAMETER RepoRelPath
    Path relative to repo root, e.g. "src\modules\configs\foo\bar".
  .PARAMETER TargetPath
    Absolute target path for the symlink.
  .EXAMPLE
    Deploy-WritableSymlink -Name "starship" -RepoRoot `$env:NUCLEUS_REPO_ROOT -RepoRelPath "src\modules\configs\starship\starship.toml" -TargetPath "`$env:USERPROFILE\.config\starship.toml"
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$RepoRelPath,

    [Parameter(Mandatory)]
    [string]$TargetPath
  )

  $sourcePath = Join-Path $RepoRoot $RepoRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Deploy-WritableSymlink ($Name): source not found at $sourcePath"
  }

  $targetDir = Split-Path $TargetPath -Parent
  if (-not (Test-Path -Path $targetDir -PathType Container)) {
    New-Item -Path $targetDir -ItemType Directory -Force > $null
  }

  # Remove existing item at target (file, dir, or broken symlink).
  if (Test-Path -Path $TargetPath) {
    Remove-Item -Path $TargetPath -Force
  }

  New-Item -Path $TargetPath -ItemType SymbolicLink -Target $sourcePath -Force > $null

  return @{
    Changed = $true
    Message = "${Name}: symlinked ${TargetPath} → ${sourcePath}"
  }
}

function Deploy-ReadOnly {
  <#
  .SYNOPSIS
    Method 2 (fallback) — copies a file with ReadOnly attribute.
  .PARAMETER Name
    Unique identifier for logging.
  .PARAMETER RepoRoot
    Absolute path to the repository root.
  .PARAMETER RepoRelPath
    Path relative to repo root.
  .PARAMETER TargetPath
    Absolute target path.
  .PARAMETER SkipIfIdentical
    When true, skip copy if destination content matches source.
  .EXAMPLE
    Deploy-ReadOnly -Name "starship" -RepoRoot $env:NUCLEUS_REPO_ROOT -RepoRelPath "src\modules\configs\starship\starship.toml" -TargetPath "$env:USERPROFILE\.config\starship.toml" -SkipIfIdentical
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$RepoRelPath,

    [Parameter(Mandatory)]
    [string]$TargetPath,

    [switch]$SkipIfIdentical
  )

  $sourcePath = Join-Path $RepoRoot $RepoRelPath
  if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
    throw "Deploy-ReadOnly ($Name): source not found at $sourcePath"
  }

  $targetDir = Split-Path $TargetPath -Parent
  if (-not (Test-Path -Path $targetDir -PathType Container)) {
    New-Item -Path $targetDir -ItemType Directory -Force > $null
  }

  if ($SkipIfIdentical -and (Test-Path -Path $TargetPath -PathType Leaf)) {
    $sourceContent = Get-Content -Path $sourcePath -Raw -Encoding UTF8
    $destContent = Get-Content -Path $TargetPath -Raw -Encoding UTF8
    if ($sourceContent -eq $destContent) {
      return @{ Changed = $false; Message = "${Name}: no change needed at ${TargetPath}" }
    }
  }

  Copy-Item -Path $sourcePath -Destination $TargetPath -Force
  Set-ItemProperty -Path $TargetPath -Name IsReadOnly -Value $true

  return @{
    Changed = $true
    Message = "${Name}: deployed read-only ${TargetPath}"
  }
}

function Deploy-Merge {
  <#
  .SYNOPSIS
    Method 3 (fallback) — merges managed settings into an app-owned config file.
  .PARAMETER Name
    Unique identifier for logging.
  .PARAMETER TargetPath
    Absolute path to the target config file (app-owned, may contain unmanaged keys).
  .PARAMETER ManagedSettings
    Hashtable of settings to merge (key-wise or section-wise).
  .PARAMETER MergeMode
    "json" for JSON merge, "ini" for INI [setting] section merge.
  .EXAMPLE
    Deploy-Merge -Name "obsidian" -TargetPath "$env:APPDATA\obsidian\obsidian.json" -ManagedSettings $settings -MergeMode json
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$TargetPath,

    [Parameter(Mandatory)]
    [hashtable]$ManagedSettings,

    [Parameter(Mandatory)]
    [ValidateSet("json", "ini")]
    [string]$MergeMode
  )

  $targetDir = Split-Path $TargetPath -Parent
  if (-not (Test-Path -Path $targetDir -PathType Container)) {
    New-Item -Path $targetDir -ItemType Directory -Force > $null
  }

  if ($MergeMode -eq "json") {
    $existing = @{}
    if (Test-Path -Path $TargetPath -PathType Leaf) {
      $raw = Get-Content -Path $TargetPath -Raw -Encoding UTF8
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $existing = $raw | ConvertFrom-Json -AsHashtable
      }
    }

    foreach ($key in $ManagedSettings.Keys) {
      $existing[$key] = $ManagedSettings[$key]
    }

    $json = $existing | ConvertTo-Json -Compress
    Set-Content -Path $TargetPath -Value $json -Encoding UTF8 -NoNewline

    return @{
      Changed = $true
      Message = "${Name}: merged JSON keys into ${TargetPath}"
    }
  }

  # INI merge mode — merge all keys under [setting] section.
  if ($MergeMode -eq "ini") {
    $lines = @()
    if (Test-Path -Path $TargetPath -PathType Leaf) {
      $lines = Get-Content -Path $TargetPath -Encoding UTF8
    }

    # Parse or create [setting] section.
    $inSetting = $false
    $settingSectionEnd = $lines.Count
    $settingLineIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\[setting\]$') {
        $inSetting = $true
        $settingLineIndex = $i
      } elseif ($inSetting -and $lines[$i] -match '^\[.*\]$') {
        $settingSectionEnd = $i
        break
      }
    }

    # Build new [setting] section content.
    $newLines = @()
    $newLines += '[setting]'
    foreach ($entry in $ManagedSettings.GetEnumerator()) {
      $value = if ($entry.Value -is [bool]) { if ($entry.Value) { 'true' } else { 'false' } }
                elseif ($null -eq $entry.Value) { '' }
                else { $entry.Value.ToString() }
      $newLines += "$($entry.Key)=$value"
    }

    if ($settingLineIndex -ge 0) {
      # Replace existing [setting] section.
      $result = @()
      $result += $lines[0..($settingLineIndex - 1)]
      $result += $newLines
      if ($settingSectionEnd -lt $lines.Count) {
        $result += $lines[$settingSectionEnd..($lines.Count - 1)]
      }
      $lines = $result
    } else {
      # Append [setting] section at end.
      if ($lines.Count -gt 0 -and $lines[-1] -ne '') {
        $lines += ''
      }
      $lines += $newLines
    }

    Set-Content -Path $TargetPath -Value $lines -Encoding UTF8
    return @{
      Changed = $true
      Message = "${Name}: merged INI [setting] into ${TargetPath}"
    }
  }
}

function Resolve-UserConfigSource {
  <#
  .SYNOPSIS
    Resolves the per-user overlay source file for a config, mirroring
    src/modules/lib/users-overlay.nix on POSIX.

  .DESCRIPTION
    Looks up src/users/<User>/<ConfigName>/<HostName>.<Extension> under the repo,
    falling back to src/users/default/<ConfigName>/<HostName>.<Extension>. The
    per-user file wins when it exists; throws when neither exists (fail-fast, no
    silent fallback).
  .PARAMETER User
    Username from the assembled user registry (src/users/).
  .PARAMETER ConfigName
    Config directory name under src/users/.
  .PARAMETER Extension
    File extension without leading dot, e.g. "gitconfig" or "toml".
  .PARAMETER HostName
    Host name, e.g. "Windows".
  .PARAMETER RepoRoot
    Absolute path to the repository root ($env:NUCLEUS_REPO_ROOT).
  .EXAMPLE
    Resolve-UserConfigSource -User "polyipseity" -ConfigName "git" -Extension "gitconfig" -HostName "Windows" -RepoRoot $env:NUCLEUS_REPO_ROOT
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [string]$ConfigName,

    [Parameter(Mandatory)]
    [string]$Extension,

    [Parameter(Mandatory)]
    [string]$HostName,

    [Parameter(Mandatory)]
    [string]$RepoRoot
  )

  $perUser = Join-Path -Path $RepoRoot -ChildPath "src\users\$User\$ConfigName\$HostName.$Extension"
  $default = Join-Path -Path $RepoRoot -ChildPath "src\users\default\$ConfigName\$HostName.$Extension"
  if (Test-Path -Path $perUser -PathType Leaf) { return $perUser }
  if (Test-Path -Path $default -PathType Leaf) { return $default }
  throw "Resolve-UserConfigSource: no source found for user '$User', config '$ConfigName', extension '$Extension' (tried '$perUser' and '$default')"
}

function Resolve-UserConfigFile {
  <#
  .SYNOPSIS
    Resolves a non-host-specific per-user overlay config file.

  .DESCRIPTION
    Looks up src/users/<User>/<ConfigName>/<RelativePath> under the repo,
    falling back to src/users/default/<ConfigName>/<RelativePath>. The per-user
    file wins when it exists; throws when neither exists (fail-fast, no silent
    fallback). Mirrors selectUserConfigFile in src/modules/lib/users-overlay.nix.
  .PARAMETER User
    Username from the user registry.
  .PARAMETER ConfigName
    Config directory name under src/users/.
  .PARAMETER RelativePath
    Path within the config directory, e.g. "settings.json" or "Picard.ini".
  .PARAMETER RepoRoot
    Absolute path to the repository root ($env:NUCLEUS_REPO_ROOT).
  .EXAMPLE
    Resolve-UserConfigFile -User "polyipseity" -ConfigName "starship" -RelativePath "starship.toml" -RepoRoot $env:NUCLEUS_REPO_ROOT
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [string]$ConfigName,

    [Parameter(Mandatory)]
    [string]$RelativePath,

    [Parameter(Mandatory)]
    [string]$RepoRoot
  )

  $perUser = Join-Path -Path $RepoRoot -ChildPath "src\users\$User\$ConfigName\$RelativePath"
  $default = Join-Path -Path $RepoRoot -ChildPath "src\users\default\$ConfigName\$RelativePath"
  if (Test-Path -Path $perUser -PathType Leaf) { return $perUser }
  if (Test-Path -Path $default -PathType Leaf) { return $default }
  throw "Resolve-UserConfigFile: no source found for user '$User', config '$ConfigName', relative path '$RelativePath' (tried '$perUser' and '$default')"
}

function Resolve-UserConfigDir {
  <#
  .SYNOPSIS
    Resolves the per-user overlay config directory for an app.

  .DESCRIPTION
    Returns src/users/<User>/<ConfigName> when it exists, otherwise
    src/users/default/<ConfigName>. Mirrors selectUserConfigDir in
    src/modules/lib/users-overlay.nix.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [string]$ConfigName,

    [Parameter(Mandatory)]
    [string]$RepoRoot
  )

  $perUser = Join-Path -Path $RepoRoot -ChildPath "src\users\$User\$ConfigName"
  $default = Join-Path -Path $RepoRoot -ChildPath "src\users\default\$ConfigName"
  if (Test-Path -Path $perUser -PathType Container) { return $perUser }
  if (Test-Path -Path $default -PathType Container) { return $default }
  throw "Resolve-UserConfigDir: no source found for user '$User', config '$ConfigName' (tried '$perUser' and '$default')"
}
