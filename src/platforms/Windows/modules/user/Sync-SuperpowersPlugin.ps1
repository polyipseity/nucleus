<#
.SYNOPSIS
  Provision the superpowers plugin checkout and its pi / opencode links.

.DESCRIPTION
  Fetches the superpowers plugin at the revision pinned in
  src\lockfiles\lockfile.json (cursor.superpowers) into
  <nucleus user root>\plugins\superpowers, then links it for the tools that
  consume it:

    %USERPROFILE%\.pi\agent\extensions\superpowers.ts -> <plugin>\.pi\extensions\superpowers.ts
    %USERPROFILE%\.opencode\plugins\superpowers        -> <plugin>\.opencode\plugins\superpowers.js

  Both links are created unconditionally: pi and opencode are provisioned on
  Windows (opencode through the SST.opencode WinGet package), so neither is a
  conditional consumer.

  Convergence is idempotent: a checkout already at the pinned revision is left
  alone, and a link already pointing at the plugin is a no-op.  Any git failure
  is a hard error — the plugin drives agent behaviour, so a stale or missing
  checkout must not pass silently.

  When $Enabled is $false the function removes only the two managed links and
  the managed checkout directory; a foreign file in either link path is left in
  place with a warning.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout root.  apply.ps1 resolves it
  from $PSScriptRoot and passes it explicitly.

.PARAMETER Enabled
  Whether the plugin should be provisioned. Mandatory: the caller chooses
  explicitly between converging and removing the managed state.

.OUTPUTS
  None.  Writes status messages to the host.

.EXAMPLE
  Sync-SuperpowersPlugin -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$true

.EXAMPLE
  # Remove the managed checkout and links:
  Sync-SuperpowersPlugin -RepoRoot 'C:\Users\guest\repos\nucleus' -Enabled:$false

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>
function Sync-SuperpowersPlugin {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\ManagedPaths.ps1')
  . (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

  $lockfilePath = Join-Path -Path $RepoRoot -ChildPath 'src\lockfiles\lockfile.json'
  if (-not (Test-Path -LiteralPath $lockfilePath)) {
    Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: lockfile not found at $lockfilePath"
    throw
  }
  $lockfile = Get-Content -LiteralPath $lockfilePath -Raw | ConvertFrom-Json
  if ($null -eq $lockfile.cursor -or $null -eq $lockfile.cursor.superpowers) {
    Write-NucleusError -CommandName 'superpowers' 'Sync-SuperpowersPlugin: lockfile must declare cursor.superpowers'
    throw
  }
  $source = $lockfile.cursor.superpowers.source
  $rev = $lockfile.cursor.superpowers.rev
  if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($rev)) {
    Write-NucleusError -CommandName 'superpowers' 'Sync-SuperpowersPlugin: cursor.superpowers must declare both source and rev'
    throw
  }

  $pluginDir = Join-Path -Path (Get-NucleusUserRoot) -ChildPath 'plugins\superpowers'
  $piLink = Join-Path -Path $HOME -ChildPath '.pi\agent\extensions\superpowers.ts'
  $opencodeLink = Join-Path -Path $HOME -ChildPath '.opencode\plugins\superpowers'
  $piLinkTarget = Join-Path -Path $pluginDir -ChildPath '.pi\extensions\superpowers.ts'
  $opencodeLinkTarget = Join-Path -Path $pluginDir -ChildPath '.opencode\plugins\superpowers.js'

  # Replace or create a managed symlink, never clobbering a foreign path.  Links
  # are preferred over copies so edits in the checkout reach both tools.
  # check-suppress:config-method: method 1 (writable symlink) -- the plugin checkout is the single source of truth; both tools read it through these links.
  $setLink = {
    param([string]$LinkPath, [string]$Target)
    $parent = Split-Path -Path $LinkPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Path $parent -Force > $null
    }
    # check-suppress:suppression_doc: probe -- the link may not exist; the $null check handles absence (Test-Path reports a dangling link as absent).
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
      $isSymlink = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $existing.LinkType -eq 'SymbolicLink'
      if (-not $isSymlink) {
        Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: $LinkPath exists and is not a managed symlink; refusing to overwrite it"
        throw
      }
      if ([string]::Equals($existing.Target, $Target, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
      }
      Remove-ManagedSymlinkDeleteProtection -Context 'superpowers' -Path $LinkPath
      Remove-Item -LiteralPath $LinkPath -Force
    }
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target > $null
    Set-ManagedSymlinkDeleteProtection -Context 'superpowers' -Path $LinkPath
    Write-NucleusInfo -CommandName 'superpowers' "linked $LinkPath -> $Target"
  }

  if (-not $Enabled) {
    foreach ($link in @($piLink, $opencodeLink)) {
      # check-suppress:suppression_doc: probe -- the link may not exist; the $null check below handles absence.
      $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
      if ($null -eq $item) {
        continue
      }
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $item.LinkType -eq 'SymbolicLink'
      if (-not $isSymlink) {
        Write-NucleusWarning -CommandName 'superpowers' "Sync-SuperpowersPlugin: $link is not a managed symlink; leaving it in place"
        continue
      }
      Remove-ManagedSymlinkDeleteProtection -Context 'superpowers' -Path $link
      Remove-Item -LiteralPath $link -Force
      Write-NucleusInfo -CommandName 'superpowers' "removed managed link $link"
    }
    if (Test-Path -LiteralPath (Join-Path -Path $pluginDir -ChildPath '.git')) {
      Remove-Item -LiteralPath $pluginDir -Recurse -Force
      Write-NucleusInfo -CommandName 'superpowers' "removed managed checkout $pluginDir"
    }
    return
  }

  # Symlinks require Developer Mode or an elevated session on Windows; other
  # platforms create them without elevation.
  if ($IsWindows) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when the value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      throw 'Sync-SuperpowersPlugin requires Developer Mode or an elevated session to create symlinks.  Enable Developer Mode in Settings -> System -> For Developers.'
    }
  }

  # check-suppress:suppression_doc: probe -- git may be absent; the $null check below reports it as an error.
  $git = Get-Command -Name git -ErrorAction SilentlyContinue
  if ($null -eq $git) {
    Write-NucleusError -CommandName 'superpowers' 'Sync-SuperpowersPlugin: git not found on PATH; cannot fetch the superpowers plugin'
    throw
  }
  $gitExe = $git.Source

  $head = $null
  if (Test-Path -LiteralPath (Join-Path -Path $pluginDir -ChildPath '.git')) {
    # check-suppress:suppression_doc: probe -- a failed rev-parse is reported as a hard error below.
    $headOutput = (& $gitExe -C $pluginDir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($headOutput)) {
      $head = $headOutput.Trim()
    }
  } elseif (Test-Path -LiteralPath $pluginDir) {
    Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: $pluginDir exists but is not a git checkout; remove it manually and re-run apply"
    throw
  }

  if ($null -ne $head -and $head -eq $rev) {
    Write-NucleusInfo -CommandName 'superpowers' "plugin already at $rev; skipping fetch"
  } else {
    if ($null -eq $head) {
      $pluginParent = Split-Path -Path $pluginDir -Parent
      if (-not (Test-Path -LiteralPath $pluginParent -PathType Container)) {
        New-Item -ItemType Directory -Path $pluginParent -Force > $null
      }
      & $gitExe clone --quiet $source $pluginDir
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: 'git clone $source' failed (exit $LASTEXITCODE)"
        throw
      }
    } else {
      & $gitExe -C $pluginDir fetch --quiet origin
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: 'git fetch origin' failed in $pluginDir (exit $LASTEXITCODE)"
        throw
      }
    }
    & $gitExe -C $pluginDir checkout --quiet --detach $rev
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: 'git checkout $rev' failed in $pluginDir (exit $LASTEXITCODE)"
      throw
    }
    # check-suppress:suppression_doc: probe -- a failed rev-parse is reported as a hard error below.
    $verified = (& $gitExe -C $pluginDir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verified) -or $verified.Trim() -ne $rev) {
      Write-NucleusError -CommandName 'superpowers' "Sync-SuperpowersPlugin: checkout is not at the pinned revision $rev"
      throw
    }
    Write-NucleusInfo -CommandName 'superpowers' "plugin checkout converged at $rev"
  }

  & $setLink $piLink $piLinkTarget
  & $setLink $opencodeLink $opencodeLinkTarget
}
