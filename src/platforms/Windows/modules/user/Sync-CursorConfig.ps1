<#
.SYNOPSIS
  Bridge %USERPROFILE%\.cursor to shared agents assets and Cursor-native config.

.DESCRIPTION
  Ensures %USERPROFILE%\.cursor is a real directory, then:
    - folder symlink skills\ -> %USERPROFILE%\.agents\skills\
    - per-file symlinks rules\*.mdc -> instructions\*.instructions.md
    - per-file symlinks agents\*.md -> agents\*.agent.md
    - per-file symlinks commands\*.md -> prompts\*.prompt.md
    - per-entry symlinks from src\users\<user>\cursor\ (hooks.json, mcp.json, …)
    - symlink settings.json -> %APPDATA%\Cursor\User\settings.json

  Requires Sync-AgentsConfig and Sync-AgentsSkillManifest to have run first.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout.

.PARAMETER Enabled
  Whether cursor config symlinks should be managed.

.PARAMETER Username
  Username for overlay resolution under src/users/.

.EXAMPLE
  Sync-CursorConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true -Username 'polyipseity'

.NOTES
  Exit codes: 0 on success; non-zero on failure
#>

function Test-DeveloperModeOrAdmin {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
  # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
  $devModeProp = Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
  $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
  return $isAdmin -or $devModeEnabled
}

. (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

function Sync-CursorConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled,
    [Parameter(Mandatory)]
    [string]$Username
  )

  $label = 'cursor-config'
  $agentsDir = Join-Path -Path $HOME -ChildPath '.agents'
  $cursorDir = Join-Path -Path $HOME -ChildPath '.cursor'
  $managedBridgeDirs = @('rules', 'agents', 'commands', 'skills')
  # settings.json targets the IDE User dir (Class C), not ~/.cursor/, so it is
  # excluded from the overlay convergence below.
  $ideSettingsSkipNames = @('settings.json')
  $cursorEntryNames = Get-UserConfigFirstLevelEntryList -User $Username -ConfigName 'cursor' -RepoRoot $RepoRoot

  function Initialize-RealDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
      $item = Get-Item -LiteralPath $Path -Force
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and $item.LinkType -eq 'SymbolicLink') {
        Write-Error "$label`: $Path is a symlink — expected a real directory for managed file symlinks."
        return $false
      }
      return $true
    }
    if (Test-Path -LiteralPath $Path) {
      Write-Error "$label`: $Path exists but is not a directory."
      return $false
    }
    New-Item -ItemType Directory -Path $Path > $null
    Write-Output "$label`: created $Path"
    return $true
  }

  function Sync-MappedFileSymlink {
    param(
      [string]$SourceDir,
      [string]$SourceSuffix,
      [string]$TargetDir,
      [string]$TargetSuffix
    )

    if (-not (Initialize-RealDirectory -Path $TargetDir)) { return $false }

    if (Test-Path -LiteralPath $SourceDir -PathType Container) {
      $sources = Get-ChildItem -LiteralPath $SourceDir -Filter "*$SourceSuffix" -File -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: source dir may hold no matching files; foreach over empty list is a no-op
      foreach ($source in $sources) {
        $base = $source.Name.Substring(0, $source.Name.Length - $SourceSuffix.Length)
        $linkPath = Join-Path -Path $TargetDir -ChildPath "$base$TargetSuffix"
        if (Test-Path -LiteralPath $linkPath) {
          $linkItem = Get-Item -LiteralPath $linkPath -Force
          $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
            -and $linkItem.LinkType -eq 'SymbolicLink'
          if ($isSymlink) {
            if ([string]::Equals($linkItem.Target, $source.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
              continue
            }
            Remove-ManagedSymlinkDeleteProtection -Context $label -Path $linkPath
            Remove-Item -LiteralPath $linkPath -Force
          } else {
            Write-Error "$label`: $linkPath is not a managed symlink — remove it and re-run apply."
            return $false
          }
        }
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $source.FullName > $null
        Set-ManagedSymlinkDeleteProtection -Context $label -Path $linkPath
        Write-Output "$label`: linked $linkPath -> $($source.FullName)"
      }
    }

    if (Test-Path -LiteralPath $TargetDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $TargetDir -Force
      foreach ($child in $children) {
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
          -and $child.LinkType -eq 'SymbolicLink'
        if (-not $isSymlink) { continue }
        $target = $child.Target
        if ($target -like "$SourceDir\*$SourceSuffix") {
          if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Remove-ManagedSymlinkDeleteProtection -Context $label -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Force
            Write-Output "$label`: removed stale symlink $($child.Name) (source removed)"
          }
        }
      }
    }
    return $true
  }

  function Sync-FolderSymlink {
    param(
      [string]$LinkPath,
      [string]$TargetPath
    )

    if (Test-Path -LiteralPath $LinkPath) {
      $item = Get-Item -LiteralPath $LinkPath -Force
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
        -and $item.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($item.Target, $TargetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
          return $true
        }
        Remove-ManagedSymlinkDeleteProtection -Context $label -Path $LinkPath
        Remove-Item -LiteralPath $LinkPath -Force
      } else {
        Write-Error "$label`: $LinkPath is not a managed symlink — remove it and re-run apply."
        return $false
      }
    }
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath > $null
    Set-ManagedSymlinkDeleteProtection -Context $label -Path $LinkPath
    Write-Output "$label`: linked $LinkPath -> $TargetPath"
    return $true
  }

  if (-not $Enabled) {
    if (Test-Path -LiteralPath $cursorDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $cursorDir -Force
      foreach ($child in $children) {
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
          -and $child.LinkType -eq 'SymbolicLink'
        if (-not $isSymlink) { continue }
        $target = $child.Target
        $isManagedBridge = $managedBridgeDirs -contains $child.Name
        $isManagedNative = $false
        if (-not $isManagedBridge -and -not ($ideSettingsSkipNames -contains $child.Name)) {
          $expectedNative = $null
          # check-suppress:suppression_doc: overlay entry may have been removed; stale cleanup is best-effort.
          try {
            $expectedNative = Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'cursor' -EntryName $child.Name -RepoRoot $RepoRoot
          } catch {
            $expectedNative = $null
          }
          $isManagedNative = $null -ne $expectedNative -and [string]::Equals($target, $expectedNative, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($isManagedBridge -or $isManagedNative) {
          Remove-ManagedSymlinkDeleteProtection -Context $label -Path $child.FullName
          Remove-Item -LiteralPath $child.FullName -Force
          Write-Output "$label`: removed managed cursor entry: $($child.FullName)"
        }
      }
      foreach ($bridgeDir in @('rules', 'agents', 'commands')) {
        $bridgePath = Join-Path -Path $cursorDir -ChildPath $bridgeDir
        if (Test-Path -LiteralPath $bridgePath -PathType Container) {
          $bridgeChildren = Get-ChildItem -LiteralPath $bridgePath -Force
          foreach ($bridgeChild in $bridgeChildren) {
            $isSymlink = ($bridgeChild.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
              -and $bridgeChild.LinkType -eq 'SymbolicLink'
            if ($isSymlink) {
              Remove-ManagedSymlinkDeleteProtection -Context $label -Path $bridgeChild.FullName
              Remove-Item -LiteralPath $bridgeChild.FullName -Force
              Write-Output "$label`: removed managed cursor file symlink: $($bridgeChild.FullName)"
            }
          }
        }
      }
    }
    # Class C: remove the IDE settings symlink when it points at our overlay.
    $appDataRoaming = Join-Path -Path $HOME -ChildPath 'AppData\Roaming'
    $cursorUserDir = Join-Path -Path $appDataRoaming -ChildPath 'Cursor\User'
    $ideSettingsLink = Join-Path -Path $cursorUserDir -ChildPath 'settings.json'
    if (Test-Path -LiteralPath $ideSettingsLink) {
      $item = Get-Item -LiteralPath $ideSettingsLink -Force
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
        -and $item.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        $expectedSource = $null
        # check-suppress:suppression_doc: overlay entry may have been removed; stale cleanup is best-effort.
        try {
          $expectedSource = Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'cursor' -EntryName 'settings.json' -RepoRoot $RepoRoot
        } catch {
          $expectedSource = $null
        }
        if ($null -ne $expectedSource -and [string]::Equals($item.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
          Remove-ManagedSymlinkDeleteProtection -Context $label -Path $ideSettingsLink
          Remove-Item -LiteralPath $ideSettingsLink -Force
          Write-Output "$label`: removed Cursor IDE settings symlink: $ideSettingsLink"
        }
      }
    }
    return
  }

  if (-not (Test-DeveloperModeOrAdmin)) {
    Write-Error "$label`: requires Developer Mode or an elevated session to create symlinks."
    return
  }

  if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) {
    Write-Error "$label`: $agentsDir not found — run Sync-AgentsConfig first."
    return
  }

  if ($cursorEntryNames.Count -eq 0) {
    Write-Error "$label`: no cursor overlay entries found for user '$Username'"
    return
  }

  if (-not (Initialize-RealDirectory -Path $cursorDir)) { return }

  $skillsLink = Join-Path -Path $cursorDir -ChildPath 'skills'
  $agentsSkills = Join-Path -Path $agentsDir -ChildPath 'skills'
  if (-not (Sync-FolderSymlink -LinkPath $skillsLink -TargetPath $agentsSkills)) { return }

  $instructionsDir = Join-Path -Path $agentsDir -ChildPath 'instructions'
  $rulesDir = Join-Path -Path $cursorDir -ChildPath 'rules'
  if (-not (Sync-MappedFileSymlink -SourceDir $instructionsDir -SourceSuffix '.instructions.md' -TargetDir $rulesDir -TargetSuffix '.mdc')) { return }

  $agentsSubDir = Join-Path -Path $agentsDir -ChildPath 'agents'
  $cursorAgentsDir = Join-Path -Path $cursorDir -ChildPath 'agents'
  if (-not (Sync-MappedFileSymlink -SourceDir $agentsSubDir -SourceSuffix '.agent.md' -TargetDir $cursorAgentsDir -TargetSuffix '.md')) { return }

  $promptsDir = Join-Path -Path $agentsDir -ChildPath 'prompts'
  $commandsDir = Join-Path -Path $cursorDir -ChildPath 'commands'
  if (-not (Sync-MappedFileSymlink -SourceDir $promptsDir -SourceSuffix '.prompt.md' -TargetDir $commandsDir -TargetSuffix '.md')) { return }

  if (Test-Path -LiteralPath $cursorDir -PathType Container) {
    $existingChildren = Get-ChildItem -LiteralPath $cursorDir -Force
    foreach ($child in $existingChildren) {
      if ($managedBridgeDirs -contains $child.Name) { continue }
      if ($ideSettingsSkipNames -contains $child.Name) { continue }
      $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
        -and $child.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        $expectedSource = $null
        # check-suppress:suppression_doc: overlay entry may have been removed; stale cleanup is best-effort.
        try {
          $expectedSource = Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'cursor' -EntryName $child.Name -RepoRoot $RepoRoot
        } catch {
          $expectedSource = $null
        }
        if ($null -ne $expectedSource -and [string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
          if (-not (Test-Path -LiteralPath $expectedSource)) {
            Remove-ManagedSymlinkDeleteProtection -Context $label -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Force
            Write-Output "$label`: removed stale link for $($child.Name) (source removed)"
          }
        }
      }
    }
  }

  foreach ($entryName in $cursorEntryNames) {
    if ($managedBridgeDirs -contains $entryName) { continue }
    if ($ideSettingsSkipNames -contains $entryName) { continue }
    $entryPath = Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'cursor' -EntryName $entryName -RepoRoot $RepoRoot
    $linkPath = Join-Path -Path $cursorDir -ChildPath $entryName
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
        -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $entryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue
        }
        Remove-ManagedSymlinkDeleteProtection -Context $label -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        Write-Error "$label`: $linkPath is not a managed symlink — merge wanted content into $entryPath and remove it, then re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $entryPath > $null
    Set-ManagedSymlinkDeleteProtection -Context $label -Path $linkPath
    Write-Output "$label`: linked $linkPath -> $entryPath"
  }

  # Class C: Cursor IDE settings — symlink settings.json into the IDE User dir
  # (separate from ~/.cursor/, which holds CLI-side config).
  $ideSettingsSource = Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'cursor' -EntryName 'settings.json' -RepoRoot $RepoRoot
  $appDataRoaming = Join-Path -Path $HOME -ChildPath 'AppData\Roaming'
  $cursorUserDir = Join-Path -Path $appDataRoaming -ChildPath 'Cursor\User'
  $ideSettingsLink = Join-Path -Path $cursorUserDir -ChildPath 'settings.json'
  if (Test-Path -LiteralPath $ideSettingsLink) {
    $item = Get-Item -LiteralPath $ideSettingsLink -Force
    $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
      -and $item.LinkType -eq 'SymbolicLink'
    if ($isSymlink) {
      if ([string]::Equals($item.Target, $ideSettingsSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
      }
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $ideSettingsLink
      Remove-Item -LiteralPath $ideSettingsLink -Force
    } else {
      Write-Error "$label`: $ideSettingsLink is not a managed symlink — merge any wanted content into $ideSettingsSource and remove it, then re-run apply."
      return
    }
  }
  # check-suppress:config-method: method 1 (writable symlink) -- Cursor reads settings on startup.
  $ideSettingsParent = Split-Path -Path $ideSettingsLink -Parent
  if (-not (Test-Path -LiteralPath $ideSettingsParent)) {
    New-Item -ItemType Directory -Path $ideSettingsParent -Force > $null
  }
  New-Item -ItemType SymbolicLink -Path $ideSettingsLink -Target $ideSettingsSource > $null
  Set-ManagedSymlinkDeleteProtection -Context $label -Path $ideSettingsLink
  Write-Output "$label`: linked $ideSettingsLink -> $ideSettingsSource"
}
