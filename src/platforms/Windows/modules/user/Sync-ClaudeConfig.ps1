<#
.SYNOPSIS
  Deploys Claude Code settings.json from the repo overlay.

.DESCRIPTION
  Deploys ~/.claude/settings.json from src/users/<user>/claude/settings.json
  using method 1 (writable symlink) on Windows.

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
    [string]$UserProfile
  )

  $claudeDir = Join-Path -Path $UserProfile -ChildPath ".claude"
  $settingsPath = Join-Path -Path $claudeDir -ChildPath "settings.json"
  $sourcePath = Join-Path -Path $RepoRoot -ChildPath "src\users\default\claude\settings.json"

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

  if (Test-Path -LiteralPath $sourcePath) {
    # Method 1: writable symlink
    if (Test-Path -LiteralPath $settingsPath) {
      # check-suppress:suppression_doc: settings file may not exist; idempotent cleanup.
      Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType SymbolicLink -Path $settingsPath -Target $sourcePath -Force > $null
  }
}
