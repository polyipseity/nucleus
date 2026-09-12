<#
.SYNOPSIS
  Deploy the pi coding agent config links (extensions directory + settings.json + web-search.json).

.DESCRIPTION
  Creates %USERPROFILE%\.pi\agent\ as a real directory, then deploys method-1
  (writable) symlinks into the live repo checkout:

    %USERPROFILE%\.pi\agent\extensions      -> the resolved pi overlay
                                              "extensions" entry
    %USERPROFILE%\.pi\agent\settings.json   -> the resolved pi overlay
                                              "settings.json" file
    %USERPROFILE%\.pi\web-search.json        -> the resolved pi overlay
                                              "web-search.json" file

  Both sources are resolved through the per-user overlay
  (Resolve-UserConfigFirstLevelEntry / Resolve-UserConfigFile), so a per-user
  override wins over src\users\default\pi\ — no src\users\default path is
  hardcoded here.

  Mirrors src/scripts/agents/symlink-pi-agent-config.sh on POSIX hosts.  Skills
  need no link because pi discovers them from %USERPROFILE%\.agents\skills\
  natively.

  Conflict handling:
    - Correct managed symlink   -> no-op (idempotent).
    - Wrong-target symlink      -> removed and recreated.
    - Real file or directory    -> fail fast (no silent overwrite).

  Symlink creation requires an elevated session or Developer Mode; the check
  runs once upfront so the failure message is actionable.

.PARAMETER RepoRoot
  Absolute path to the root of the nucleus repository checkout.  apply.ps1
  resolves this from $PSScriptRoot and passes it explicitly.

.PARAMETER User
  Username from the user registry, used to resolve the per-user overlay.

.PARAMETER Enabled
  Whether the links should be managed.  Mandatory: the caller explicitly
  chooses true (converge the links) or false (remove managed links only, leaving
  unmanaged content untouched).

.EXAMPLE
  Sync-PiAgentConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -User 'guest' -Enabled:$true

.EXAMPLE
  # Cleanup path: remove the managed links only.
  Sync-PiAgentConfig -RepoRoot 'C:\Users\guest\repos\nucleus' -User 'guest' -Enabled:$false

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>
# WHY: symlink creation needs SeCreateSymbolicLinkPrivilege (elevated session or
# Developer Mode).  Probing once produces an actionable message instead of a raw
# .NET privilege exception from New-Item.  Defined at file scope (like
# Sync-CursorConfig's Test-DeveloperModeOrAdmin) so hosts and tests can stub it.
function Test-PiSymlinkPrivilege {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { return $true }
  $devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
  # check-suppress:suppression_doc: probe whether Developer Mode is enabled; Get-ItemProperty throws when the value is absent.
  $devModeProp = Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
  return $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
}

. (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

function Sync-PiAgentConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $label = 'pi-agent-config'
  $piDir = Join-Path -Path $HOME -ChildPath '.pi\agent'
  $extensionsLink = Join-Path -Path $piDir -ChildPath 'extensions'
  $settingsLink = Join-Path -Path $piDir -ChildPath 'settings.json'
  $webSearchLink = Join-Path -Path $HOME -ChildPath '.pi\web-search.json'

  # Converge one link onto $TargetPath; returns $false after reporting the
  # conflict that prevents convergence.
  function Sync-PiAgentLink {
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
        Write-NucleusError -CommandName $label "$LinkPath is not a managed symlink — merge any wanted content into $TargetPath, remove it, then re-run apply."
        return $false
      }
    }
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath > $null
    Set-ManagedSymlinkDeleteProtection -Context $label -Path $LinkPath
    Write-NucleusInfo -CommandName $label "linked $LinkPath -> $TargetPath"
    return $true
  }

  if (-not $Enabled) {
    foreach ($linkPath in @($extensionsLink, $settingsLink, $webSearchLink)) {
      if (-not (Test-Path -LiteralPath $linkPath)) { continue }
      $item = Get-Item -LiteralPath $linkPath -Force
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
        -and $item.LinkType -eq 'SymbolicLink'
      if (-not $isSymlink) { continue }
      Remove-ManagedSymlinkDeleteProtection -Context $label -Path $linkPath
      Remove-Item -LiteralPath $linkPath -Force
      Write-NucleusInfo -CommandName $label "removed managed link: $linkPath"
    }
    return
  }

  if (-not (Test-PiSymlinkPrivilege)) {
    Write-NucleusError -CommandName $label "creating symlinks requires an elevated session or Developer Mode; enable Developer Mode in Settings -> System -> For Developers and re-run apply."
    return
  }

  $extensionsSource = Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'pi' -EntryName 'extensions' -RepoRoot $RepoRoot
  $settingsSource = Resolve-UserConfigFile -User $User -ConfigName 'pi' -RelativePath 'settings.json' -RepoRoot $RepoRoot
  $webSearchSource = Resolve-UserConfigFile -User $User -ConfigName 'pi' -RelativePath 'web-search.json' -RepoRoot $RepoRoot

  if (-not (Test-Path -LiteralPath $extensionsSource -PathType Container)) {
    Write-NucleusError -CommandName $label "resolved pi extensions source is not a directory: $extensionsSource"
    return
  }
  if (-not (Test-Path -LiteralPath $settingsSource -PathType Leaf)) {
    Write-NucleusError -CommandName $label "resolved pi settings source is not a file: $settingsSource"
    return
  }
  if (-not (Test-Path -LiteralPath $webSearchSource -PathType Leaf)) {
    Write-NucleusError -CommandName $label "resolved pi web-search source is not a file: $webSearchSource"
    return
  }

  if (-not (Test-Path -LiteralPath $piDir -PathType Container)) {
    New-Item -ItemType Directory -Path $piDir -Force > $null
    Write-NucleusInfo -CommandName $label "created $piDir"
  }

  if (-not (Sync-PiAgentLink -LinkPath $extensionsLink -TargetPath $extensionsSource)) { return }
  if (-not (Sync-PiAgentLink -LinkPath $settingsLink -TargetPath $settingsSource)) { return }
  if (-not (Sync-PiAgentLink -LinkPath $webSearchLink -TargetPath $webSearchSource)) { return }
}
