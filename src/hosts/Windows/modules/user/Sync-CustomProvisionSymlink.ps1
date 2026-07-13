function Sync-CustomProvisionSymlink {
  <#
  .SYNOPSIS
    Provision managed custom symlinks for configured Windows users.

  .DESCRIPTION
    Converges the per-user customProvisionSymlinks registry entries defined in
    src/hosts/Windows/users.json.

    For each user record, the function:
      1. Selects entries that define a Windows target.
      2. Optionally creates the target directory.
      3. Creates or updates the symlink under the user's home directory.
      4. Applies delete-protection ACLs to managed symlinks.
      5. Removes stale managed symlinks recorded in the manifest when entries
         are deleted or the feature is disabled.

    Only managed reparse points are touched. Existing non-symlink paths are
    left alone with a warning so unmanaged user data is never overwritten.

  .PARAMETER Enabled
    Whether managed custom symlink provisioning is enabled. Mandatory: callers
    must explicitly choose the enabled or cleanup path.

  .PARAMETER UserRecords
    Array of user records loaded from src/hosts/Windows/users.json. Each record
    may contain a customProvisionSymlinks array using the shared schema.

  .EXAMPLE
    Sync-CustomProvisionSymlink -Enabled:$true -UserRecords @(@{ name = 'admin'; homeDirectory = 'C:\Users\admin'; customProvisionSymlinks = @() })

  .EXAMPLE
    Sync-CustomProvisionSymlink -Enabled:$false -UserRecords @(@{ name = 'admin'; homeDirectory = 'C:\Users\admin'; customProvisionSymlinks = @() })

  .NOTES
    Environment variables: USERDOMAIN, USERNAME — used for delete-protection ACLs.
    Exit codes: 0 on success; non-zero on failure
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Enabled,

    [Parameter(Mandatory = $true)]
    [object[]]$UserRecords
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\..\Set-ManagedSymlinkDeleteProtection.ps1")

  function Resolve-ManagedUserPath {
    param(
      [Parameter(Mandatory = $true)]
      [string]$HomeDirectory,

      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
      return [System.IO.Path]::GetFullPath($Path)
    }

    if ($Path -eq '~') {
      return [System.IO.Path]::GetFullPath($HomeDirectory)
    }

    if ($Path.StartsWith('~/')) {
      return [System.IO.Path]::GetFullPath((Join-Path -Path $HomeDirectory -ChildPath $Path.Substring(2)))
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $HomeDirectory -ChildPath $Path))
  }

  function Test-ManagedSymlink {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
      return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  }

  function Get-ManifestPathList {
    param(
      [Parameter(Mandatory = $true)]
      [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      return @()
    }

    try {
      $loaded = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
      return @($loaded | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
      Write-Warning "Sync-CustomProvisionSymlink: manifest at $ManifestPath was unreadable and will be rebuilt."
      return @()
    }
  }

  foreach ($userRecord in $UserRecords) {
    $username = [string]$userRecord.name
    $homeDirectory = [string]$userRecord.homeDirectory
    if ([string]::IsNullOrWhiteSpace($homeDirectory)) {
      Write-Warning "Sync-CustomProvisionSymlink: skipping user '$username' because homeDirectory is missing."
      continue
    }

    $manifestDir = Join-Path -Path $homeDirectory -ChildPath '.config\nucleus'
    $manifestPath = Join-Path -Path $manifestDir -ChildPath 'custom-provision-symlinks.json'
    $previousManagedPaths = @(Get-ManifestPathList -ManifestPath $manifestPath)

    foreach ($previousPath in $previousManagedPaths) {
      if (Test-ManagedSymlink -Path $previousPath) {
        Remove-ManagedSymlinkDeleteProtection -Context "Sync-CustomProvisionSymlink" -Path $previousPath
      }
    }

    if (-not $Enabled) {
      foreach ($previousPath in $previousManagedPaths) {
        if (Test-ManagedSymlink -Path $previousPath) {
          Remove-Item -LiteralPath $previousPath -Force
        }
      }
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
      }
      continue
    }

    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

    $configuredEntries = @($userRecord.customProvisionSymlinks | Where-Object { $_ })
    $desiredEntries = @()
    foreach ($entry in $configuredEntries) {
      $linkRelativePath = [string]$entry.path
      if ([string]::IsNullOrWhiteSpace($linkRelativePath)) {
        continue
      }

      $targets = $entry.targets
      $windowsTarget = if ($targets -and $targets.windows) { [string]$targets.windows } else { '' }
      if ([string]::IsNullOrWhiteSpace($windowsTarget)) {
        continue
      }

      $desiredEntries += [pscustomobject]@{
        CreateTargetDirectory = if ($entry.createTargetDirectory) { $true } else { $false }
        LinkPath              = Resolve-ManagedUserPath -HomeDirectory $homeDirectory -Path $linkRelativePath
        TargetPath            = Resolve-ManagedUserPath -HomeDirectory $homeDirectory -Path $windowsTarget
      }
    }

    $desiredPaths = @($desiredEntries | ForEach-Object { $_.LinkPath })
    foreach ($stalePath in ($previousManagedPaths | Where-Object { $_ -notin $desiredPaths })) {
      if (Test-ManagedSymlink -Path $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
      }
    }

    foreach ($entry in $desiredEntries) {
      $linkParent = Split-Path -Path $entry.LinkPath -Parent
      if (-not [string]::IsNullOrWhiteSpace($linkParent)) {
        New-Item -ItemType Directory -Path $linkParent -Force | Out-Null
      }

      if (Test-Path -LiteralPath $entry.LinkPath) {
        $existingItem = Get-Item -LiteralPath $entry.LinkPath -Force
        $isReparsePoint = ($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if (-not $isReparsePoint) {
          Write-Warning "Sync-CustomProvisionSymlink: keeping unmanaged path $($entry.LinkPath) for user '$username' because it is not a symlink."
          continue
        }

        $currentTarget = @($existingItem.Target | Select-Object -First 1) -join ''
        $normalizedCurrentTarget = if ([string]::IsNullOrWhiteSpace($currentTarget)) {
          ''
        }
        else {
          [System.IO.Path]::GetFullPath($currentTarget)
        }

        if ($normalizedCurrentTarget -eq $entry.TargetPath) {
          Set-ManagedSymlinkDeleteProtection -Context "Sync-CustomProvisionSymlink" -Path $entry.LinkPath
          continue
        }

        Remove-Item -LiteralPath $entry.LinkPath -Force
      }

      try {
        New-Item -ItemType SymbolicLink -Path $entry.LinkPath -Target $entry.TargetPath -Force -ErrorAction Stop | Out-Null
        Set-ManagedSymlinkDeleteProtection -Context "Sync-CustomProvisionSymlink" -Path $entry.LinkPath
      }
      catch {
        Write-Warning "Sync-CustomProvisionSymlink: failed to create symlink $($entry.LinkPath) -> $($entry.TargetPath) for user '$username' : $_"
      }
    }

    $desiredPaths | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
  }
}
