function Invoke-SteamCMDSetup {
  <#
  .SYNOPSIS
    Provisions the SteamCMD binary at RimSort's expected steamcmd_install_path.

  .DESCRIPTION
    Windows counterpart to the POSIX provision-steamcmd.sh activation hook.
    Downloads the SteamCMD zip from Valve's CDN and extracts it into
    <steamcmd_install_path>/steamcmd/ so that RimSort finds the executable
    at its expected path without prompting the user.

    RimSort checks for the executable at <steamcmd_install_path>/steamcmd/<exe>
    but does not use PATH — the file must exist at the expected path.

    The steamcmd_install_path is resolved by merging the base RimSort settings
    (rimsort.json) with the host overlay (rimsort.Windows.json) to produce
    platform-correct paths, mirroring the lib.recursiveUpdate merge done at
    Nix eval time in home.nix.

  .PARAMETER Enabled
    True provisions SteamCMD. False is a no-op (RimSort cleanup removes
    steamcmd_install_path keys, not the binary directory).

  .PARAMETER Users
    Mandatory: array of managed user records from Load-UserRegistry.ps1.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .EXAMPLE
    Invoke-SteamCMDSetup -Enabled:$true -Users $userRegistry.users -RepoRoot $env:NUCLEUS_REPO_ROOT

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
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

  if (-not $Enabled) {
    return
  }

  $steamcmdZipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"

  # Resolve the host key for overlay path construction.
  # Get-NucleusHostKey is defined in Get-NucleusHostPlatform.ps1.
  . (Join-Path -Path $RepoRoot -ChildPath 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1')
  $hostKeyName = Get-NucleusHostKey

  function Merge-Hashtables {
    <#
    .SYNOPSIS
      Deep-merges two hashtables, mirroring lib.recursiveUpdate from Nix.
      The $Override hashtable wins on overlapping keys.
    #>
    param(
      [hashtable]$Base,
      [hashtable]$Override
    )

    $result = @{}
    foreach ($key in $Base.Keys) {
      $result[$key] = $Base[$key]
    }
    foreach ($key in $Override.Keys) {
      if ($result.ContainsKey($key) -and
          $result[$key] -is [hashtable] -and
          $Override[$key] -is [hashtable]) {
        $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key]
      } else {
        $result[$key] = $Override[$key]
      }
    }
    return $result
  }

  function Resolve-OverlayPath {
    <#
    .SYNOPSIS
      Reads a JSON file and converts it to a nested hashtable.
      Returns $null if the file does not exist.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return ConvertTo-Hashtable -InputObject $raw
  }

  foreach ($userRecord in $Users) {
    $username = [string]$userRecord.name
    $userHome = [string]$userRecord.homeDirectory

    # Read the base managed RimSort settings (rimsort.json).
    $basePath = Resolve-UserConfigFile -User $username -ConfigName 'rimsort' -RelativePath 'rimsort.json' -RepoRoot $RepoRoot
    $baseSettings = ConvertTo-Hashtable -InputObject (Get-Content -LiteralPath $basePath -Raw | ConvertFrom-Json)

    # Read the host overlay (rimsort.<HostName>.json) if it exists.
    # This mirrors the host-specific overlay resolution in home.nix
    # (rimsortManagedSettings + rimsortHostSettings via lib.recursiveUpdate).
    $hostOverlayPath = Join-Path -Path $RepoRoot -ChildPath "src\users\default\rimsort\rimsort.$hostKeyName.json"
    $hostSettings = Resolve-OverlayPath -Path $hostOverlayPath

    # Merge: host overlay wins on overlapping keys (lib.recursiveUpdate semantics).
    $mergedSettings = $baseSettings
    if ($null -ne $hostSettings) {
      $mergedSettings = Merge-Hashtables -Base $baseSettings -Override $hostSettings
    }

    $steamcmdPath = $null
    if ($mergedSettings.ContainsKey('instances') -and
        $mergedSettings['instances'] -is [hashtable] -and
        $mergedSettings['instances'].ContainsKey('Default') -and
        $mergedSettings['instances']['Default'] -is [hashtable]) {
      $defaultInstance = $mergedSettings['instances']['Default']
      if ($defaultInstance.ContainsKey('steamcmd_install_path')) {
        $steamcmdPath = [string]$defaultInstance['steamcmd_install_path']
      }
    }

    if ([string]::IsNullOrWhiteSpace($steamcmdPath)) {
      Write-NucleusInfo -CommandName 'Invoke-SteamCMDSetup' "No steamcmd_install_path for $username; skipping."
      continue
    }

    # Expand ~ to the user's home directory.
    $steamcmdPath = $steamcmdPath.Replace('~', $userHome)

    $steamcmdDir = Join-Path -Path $steamcmdPath -ChildPath "steamcmd"

    # Skip if already provisioned (steamcmd.exe exists).
    $steamcmdExe = Join-Path -Path $steamcmdDir -ChildPath "steamcmd.exe"
    if (Test-Path -LiteralPath $steamcmdExe -PathType Leaf) {
      continue
    }

    Write-NucleusInfo -CommandName 'Invoke-SteamCMDSetup' "Provisioning SteamCMD for $username at $steamcmdDir"

    # Ensure the parent directory exists.
    if (-not (Test-Path -LiteralPath $steamcmdPath -PathType Container)) {
      New-Item -ItemType Directory -Path $steamcmdPath -Force > $null
    }

    # Download and extract SteamCMD.
    $tempZip = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "steamcmd-$([System.IO.Path]::GetRandomFileName()).zip"
    try {
      Invoke-WebRequest -Uri $steamcmdZipUrl -OutFile $tempZip -UseBasicParsing
      Expand-Archive -Path $tempZip -DestinationPath $steamcmdDir -Force
      Write-NucleusInfo -CommandName 'Invoke-SteamCMDSetup' "SteamCMD provisioned for $username."
    }
    finally {
      if (Test-Path -LiteralPath $tempZip -PathType Leaf) {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup of temp file; failure is harmless
      }
    }
  }
}
