<#
.SYNOPSIS
  Deploy the shared opencode config and its agent / command bridges.

.DESCRIPTION
  opencode reads its global config from %USERPROFILE%\.config\opencode\ on every
  platform, and discovers global agents and commands under the same directory.
  POSIX wires these through Home Manager plus symlink-agent-config.sh; this
  function provides the Windows equivalent:

    %USERPROFILE%\.config\opencode\opencode.jsonc -> the opencode overlay's
                                                     opencode.jsonc
    %USERPROFILE%\.config\opencode\agents         -> %USERPROFILE%\.agents\agents
    %USERPROFILE%\.config\opencode\commands       -> %USERPROFILE%\.agents\prompts

  The agents and commands links bridge to the single shared agent-asset tree in
  ~\.agents\ (agents -> agents\, commands -> prompts\), so nothing is duplicated.
  Both must already exist — Sync-AgentsConfig creates them — and a missing target
  is a hard error rather than a dangling link.

  When $Enabled is $false the function removes only the three managed links.

.PARAMETER RepoRoot
  Absolute path to the nucleus repository checkout root.

.PARAMETER User
  Username from the user registry; opencode.jsonc resolves through the per-user
  opencode overlay (src/users/<username>/opencode/ with src/users/default/ as
  fallback).

.PARAMETER Enabled
  True deploys the three links; false removes the managed links.

.NOTES
  Environment variables: (none)
  Requires ConfigHelpers.ps1 (Resolve-UserConfigFile) to be loaded by the caller.
  Exit codes: 0 on success; non-zero on failure
#>
function Sync-OpenCodeConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

  $openCodeDir = Join-Path -Path $HOME -ChildPath '.config\opencode'
  # check-suppress:config-method: method 1 (writable symlink) -- opencode.jsonc is the shared agent config; edits in the repo take effect without a rebuild.
  $configLink = Join-Path -Path $openCodeDir -ChildPath 'opencode.jsonc'
  # check-suppress:config-method: method 1 (writable symlink) -- bridges opencode's per-directory discovery to the shared ~\.agents tree instead of copying agent assets.
  $agentsLink = Join-Path -Path $openCodeDir -ChildPath 'agents'
  $commandsLink = Join-Path -Path $openCodeDir -ChildPath 'commands'
  $agentsTarget = Join-Path -Path $HOME -ChildPath '.agents\agents'
  $commandsTarget = Join-Path -Path $HOME -ChildPath '.agents\prompts'

  if (-not $Enabled) {
    foreach ($link in @($configLink, $agentsLink, $commandsLink)) {
      # check-suppress:suppression_doc: probe -- the link may not exist; the $null check below handles absence (Test-Path reports a dangling link as absent).
      $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
      if ($null -eq $item) {
        continue
      }
      $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $item.LinkType -eq 'SymbolicLink'
      if (-not $isSymlink) {
        Write-NucleusWarning -CommandName 'opencode' "Sync-OpenCodeConfig: $link is not a managed symlink; leaving it in place"
        continue
      }
      Remove-ManagedSymlinkDeleteProtection -Context 'opencode' -Path $link
      Remove-Item -LiteralPath $link -Force
      Write-NucleusInfo -CommandName 'opencode' "removed managed link $link"
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
      throw 'Sync-OpenCodeConfig requires Developer Mode or an elevated session to create symlinks.  Enable Developer Mode in Settings -> System -> For Developers.'
    }
  }

  $configTarget = Resolve-UserConfigFile -User $User -ConfigName 'opencode' -RelativePath 'opencode.jsonc' -RepoRoot $RepoRoot
  if (-not (Test-Path -LiteralPath $configTarget -PathType Leaf)) {
    Write-NucleusError -CommandName 'opencode' "Sync-OpenCodeConfig: opencode.jsonc not found in the opencode overlay: $configTarget"
    throw
  }
  foreach ($bridge in @(@{ Path = $agentsTarget; Name = 'agents' }, @{ Path = $commandsTarget; Name = 'prompts' })) {
    if (-not (Test-Path -LiteralPath $bridge.Path)) {
      Write-NucleusError -CommandName 'opencode' "Sync-OpenCodeConfig: $($bridge.Path) not found; Sync-AgentsConfig must run before this function"
      throw
    }
  }

  $deployments = @(
    @{ Link = $configLink; Target = $configTarget },
    @{ Link = $agentsLink; Target = $agentsTarget },
    @{ Link = $commandsLink; Target = $commandsTarget }
  )

  foreach ($deployment in $deployments) {
    $link = $deployment.Link
    $target = $deployment.Target
    if (-not (Test-Path -LiteralPath $openCodeDir -PathType Container)) {
      New-Item -ItemType Directory -Path $openCodeDir -Force > $null
    }
    # check-suppress:suppression_doc: probe -- the link may not exist; the $null check below handles absence (Test-Path reports a dangling link as absent).
    $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
      $isSymlink = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 `
                     -and $existing.LinkType -eq 'SymbolicLink'
      if (-not $isSymlink) {
        Write-NucleusError -CommandName 'opencode' "Sync-OpenCodeConfig: $link exists and is not a managed symlink; refusing to overwrite it"
        throw
      }
      if ([string]::Equals($existing.Target, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
      }
      Remove-ManagedSymlinkDeleteProtection -Context 'opencode' -Path $link
      Remove-Item -LiteralPath $link -Force
    }
    New-Item -ItemType SymbolicLink -Path $link -Target $target > $null
    Set-ManagedSymlinkDeleteProtection -Context 'opencode' -Path $link
    Write-NucleusInfo -CommandName 'opencode' "linked $link -> $target"
  }
}
