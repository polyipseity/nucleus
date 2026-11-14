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

  if (-not $Enabled) {
    if (Test-Path -LiteralPath $settingsPath) {
      # check-suppress:suppression_doc: settings file may not exist; idempotent cleanup.
      Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
    }
    return
  }

  if (-not (Test-Path -LiteralPath $claudeDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $claudeDir -Force > $null
  }

  # The overlay resolves the per-user override first; a missing source in both
  # overlays is a hard error, never a silent skip.
  $sourcePath = Resolve-UserConfigFile -User $User -ConfigName 'claude' -RelativePath 'settings.json' -RepoRoot $RepoRoot
  # Method 1: writable symlink
  if (Test-Path -LiteralPath $settingsPath) {
    # check-suppress:suppression_doc: settings file may not exist; idempotent cleanup.
    Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType SymbolicLink -Path $settingsPath -Target $sourcePath -Force > $null
}
