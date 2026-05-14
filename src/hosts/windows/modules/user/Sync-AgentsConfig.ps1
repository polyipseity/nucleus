<#
.SYNOPSIS
  Sync the user-level ~/.agents directory as a managed per-subdir layout.

.DESCRIPTION
  Creates %USERPROFILE%\.agents\ as a real directory, then creates a per-entry
  directory symbolic link inside it for every top-level entry in
  src\modules\configs\agents\ except skills\.

  skills\ is excluded here because it is managed by Sync-AgentsSkills and may
  contain fetched (clawhub) skill downloads that must not be committed.  Using
  a real ~/.agents\ directory with per-subdir symlinks (rather than a single
  whole-dir symlink) lets clawhub write into ~/.agents\skills\ without those
  writes landing inside the tracked repo tree.

  Migration: if %USERPROFILE%\.agents is the old whole-dir symlink pointing at
  src\modules\configs\agents\, it is removed automatically and the per-subdir
  layout is created in its place.

  Migration safety:
    - Old whole-dir symlink  -> removed automatically; real directory created.
    - Correct per-subdir symlink  -> no-op.
    - Wrong per-subdir symlink    -> remove and recreate.
    - Real path at sub-entry      -> fail fast (no silent overwrite).
    - Stale per-subdir symlink    -> removed (source entry deleted from repo).

  Directory symbolic links require Developer Mode or an elevated session.
  Developer Mode is enabled on this machine via system.dsc.yml
  (Microsoft.Windows.Settings/DeveloperMode), which permits unprivileged symlink
  creation.  Symlinks are preferred over NTFS junctions because they are a proper
  POSIX-equivalent reparse point and are followed correctly by cross-host tooling
  (editors, language servers) that inspects the link target rather than traversal
  through reparse data.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  Whether per-subdir symlinks should be managed. Mandatory: caller must
  explicitly choose true (ensure symlinks exist) or false (remove managed
  symlinks). When $false, unrecognised symlinks and real directories are
  left untouched.

.EXAMPLE
  Sync-AgentsConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true

.EXAMPLE
  # Remove all managed per-subdir symlinks (cleanup path):
  Sync-AgentsConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$false
#>
function Sync-AgentsConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # The managed source is the live agents config tree in the repo.  Coding agents
  # write through per-subdir symlinks directly into the repo checkout so every
  # change appears as an unstaged git diff.
  $agentsSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\agents"
  $agentsDir    = Join-Path -Path $HOME     -ChildPath ".agents"

  function Set-ManagedSymlinkDeleteProtection {
    [CmdletBinding(SupportsShouldProcess)]
    param(
      [Parameter(Mandatory)]
      [string]$Path
    )

    $principal = "$env:USERDOMAIN\$env:USERNAME"
    if ($PSCmdlet.ShouldProcess($Path, "Apply symlink delete-protection ACL")) {
      $grantResult = (& icacls $Path /L /deny "${principal}:(D)" 2>&1) | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "agents-config: could not apply delete-protection ACL to ${Path} : $grantResult"
      }
    }
  }

  function Remove-ManagedSymlinkDeleteProtection {
    [CmdletBinding(SupportsShouldProcess)]
    param(
      [Parameter(Mandatory)]
      [string]$Path
    )

    $principal = "$env:USERDOMAIN\$env:USERNAME"
    if ($PSCmdlet.ShouldProcess($Path, "Remove symlink delete-protection ACL")) {
      $removeResult = (& icacls $Path /L /remove:d $principal 2>&1) | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "agents-config: could not clear delete-protection ACL from $Path before update : $removeResult"
      }
    }
  }

  # Directory symlinks require Developer Mode or an elevated session.  Check
  # once upfront so any failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      Write-Error "Sync-AgentsConfig requires Developer Mode or an elevated session to create directory symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
      return
    }
  }

  if (-not $Enabled) {
    # Cleanup path: remove per-subdir symlinks that point into the managed source.
    # Leave unrecognised symlinks and real directories untouched.
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
      $children = Get-ChildItem -LiteralPath $agentsDir -Force
      foreach ($child in $children) {
        if ($child.Name -eq "skills") { continue }  # managed by Sync-AgentsSkills
        $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                       -and $child.LinkType -eq 'SymbolicLink'
        if ($isSymlink) {
          $targetPath = Join-Path -Path $agentsSource -ChildPath $child.Name
          if ([string]::Equals($child.Target, $targetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Force
            Write-Output "agents-config: removed managed agents subdir symlink: $($child.FullName)"
          }
        }
      }
    }
    return
  }

  if (-not (Test-Path -LiteralPath $agentsSource -PathType Container)) {
    Write-Error "agents-config: Sync-AgentsConfig: agents config dir not found: $agentsSource"
    return
  }

  # Migration: remove the old whole-dir symlink if it still points to the managed
  # source.  All old-scheme symlinks at $agentsDir were created by this function;
  # user-created symlinks at this path are not expected.
  if (Test-Path -LiteralPath $agentsDir) {
    $agentsDirItem = Get-Item -LiteralPath $agentsDir -Force
    $isWholeDirSymlink = ($agentsDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                           -and $agentsDirItem.LinkType -eq 'SymbolicLink'
    if ($isWholeDirSymlink) {
      Remove-Item -LiteralPath $agentsDir -Force
      Write-Output "agents-config: Sync-AgentsConfig: migrated from whole-dir symlink to per-subdir layout"
    }
  }

  # Ensure ~/.agents\ exists as a real (writable) directory.
  if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $agentsDir | Out-Null
    Write-Output "agents-config: Sync-AgentsConfig: created $agentsDir"
  }

  # Remove stale per-subdir symlinks: any symlink in ~/.agents\ that once pointed
  # into $agentsSource but whose source entry no longer exists there.
  $existingChildren = Get-ChildItem -LiteralPath $agentsDir -Force
  foreach ($child in $existingChildren) {
    if ($child.Name -eq "skills") { continue }  # managed by Sync-AgentsSkills
    $isSymlink = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                   -and $child.LinkType -eq 'SymbolicLink'
    if ($isSymlink) {
      $expectedSource = Join-Path -Path $agentsSource -ChildPath $child.Name
      if ([string]::Equals($child.Target, $expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Managed symlink: remove if the source entry no longer exists.
        if (-not (Test-Path -LiteralPath $expectedSource)) {
          Remove-ManagedSymlinkDeleteProtection -Path $child.FullName
          Remove-Item -LiteralPath $child.FullName -Force
          Write-Output "agents-config: Sync-AgentsConfig: removed stale link for $($child.Name) (source removed)"
        }
      }
    }
  }

  # Create or update per-entry symlinks for every top-level source entry except
  # skills\ (managed independently by Sync-AgentsSkills).
  $sourceEntries = Get-ChildItem -LiteralPath $agentsSource -Force
  foreach ($entry in $sourceEntries) {
    if ($entry.Name -eq "skills") { continue }  # owned by Sync-AgentsSkills
    $linkPath = Join-Path -Path $agentsDir -ChildPath $entry.Name
    if (Test-Path -LiteralPath $linkPath) {
      $linkItem = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $linkItem.LinkType -eq 'SymbolicLink'
      if ($isSymlink) {
        if ([string]::Equals($linkItem.Target, $entry.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }
        # Wrong target (e.g. leftover from a previous checkout path): replace.
        Remove-ManagedSymlinkDeleteProtection -Path $linkPath
        Remove-Item -LiteralPath $linkPath -Force
      } else {
        # Real file or directory: fail fast to prevent silent data loss.
        Write-Error "agents-config: Sync-AgentsConfig: $linkPath is not a managed symlink — merge any wanted content into $($entry.FullName) and remove it, then re-run apply."
        return
      }
    }
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $entry.FullName | Out-Null
    Set-ManagedSymlinkDeleteProtection -Path $linkPath
    Write-Output "agents-config: Sync-AgentsConfig: linked $linkPath -> $($entry.FullName)"
  }
}
