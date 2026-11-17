<#
.SYNOPSIS
  Deploys Claude Code settings.json from the repo overlay.

.DESCRIPTION
  Deploys ~/.claude/settings.json from src/users/<user>/claude/settings.json
  using method 1 (writable symlink) on Windows.
  Requires ConfigHelpers.ps1 (Resolve-UserConfigFile) to be loaded by the caller.

.PARAMETER Enabled
  Whether Claude config deployment should be enforced.

.PARAMETER RepoRoot
  Absolute path to the live repository root.

.PARAMETER UserProfile
  Absolute path to the user profile (%USERPROFILE%).
#>

function Sync-ClaudeConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$UserProfile,

    [Parameter()]
    [string]$User = [System.Environment]::UserName
  )

  $claudeDir = Join-Path -Path $UserProfile -ChildPath ".claude"
  $settingsPath = Join-Path -Path $claudeDir -ChildPath "settings.json"
  $marketplacePath = Join-Path -Path $claudeDir -ChildPath ".claude-plugin\marketplace.json"
  $pluginDir = Join-Path -Path $claudeDir -ChildPath "plugins\nucleus-prompt-tools"

  if (-not $Enabled) {
    foreach ($managedPath in @($settingsPath, $marketplacePath, $pluginDir)) {
      if (Test-Path -LiteralPath $managedPath) {
        # check-suppress:suppression_doc: probe -- managed files/dirs may not exist during idempotent cleanup.
        Remove-Item -LiteralPath $managedPath -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
    return
  }

  foreach ($dir in @(
      $claudeDir,
      (Join-Path -Path $claudeDir -ChildPath ".claude-plugin"),
      (Join-Path -Path $claudeDir -ChildPath "plugins")
    )) {
    if (-not (Test-Path -LiteralPath $dir)) {
      # check-suppress:suppression_doc: directory creation output not needed.
      New-Item -ItemType Directory -Path $dir -Force > $null
    }
  }

  # The overlay resolves the per-user override first; a missing source in both
  # overlays is a hard error, never a silent skip.
  $settingsSource = Resolve-UserConfigFile -User $User -ConfigName 'claude' -RelativePath 'settings.json' -RepoRoot $RepoRoot
  $marketplaceSource = Resolve-UserConfigFile -User $User -ConfigName 'claude' -RelativePath '.claude-plugin\marketplace.json' -RepoRoot $RepoRoot
  $pluginSource = Resolve-UserConfigFile -User $User -ConfigName 'claude' -RelativePath 'plugins\nucleus-prompt-tools' -RepoRoot $RepoRoot

  # Method 1: writable symlinks (settings + nucleus marketplace + plugin dir).
  foreach ($deployment in @(
      @{ Link = $settingsPath; Target = $settingsSource },
      @{ Link = $marketplacePath; Target = $marketplaceSource },
      @{ Link = $pluginDir; Target = $pluginSource }
    )) {
    if (Test-Path -LiteralPath $deployment.Link) {
      # check-suppress:suppression_doc: probe -- managed target may not exist during idempotent replace.
      Remove-Item -LiteralPath $deployment.Link -Force -Recurse -ErrorAction SilentlyContinue
    }
    New-Item -ItemType SymbolicLink -Path $deployment.Link -Target $deployment.Target -Force > $null
  }
}
