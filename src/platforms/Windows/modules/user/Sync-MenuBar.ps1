<#
.SYNOPSIS
  Converges GUI/user app menu-bar / tray icon visibility to the apps.json registry on Windows.

.DESCRIPTION
  Registry-driven per-app tray-icon convergence (mirrors the macOS / NixOS
  icon mechanism).  Reads apps.json and SETs each Windows app's native tray
  preference to its declared state (iconVisibleValue / iconHiddenValue).  Icon
  visibility is AND (icon shows only if the app-native show setting AND the OS
  both allow it), so the native setting is SET, never disabled.  Tray-icon
  visibility is app-specific on Windows (no universal OS toggle); apps that
  expose no controllable tray setting simply omit the menuBarIcon block.

  Cross-platform parity:
    macOS   — activation script in MacBook/activation.nix (defaults write)
    NixOS   — activation script in desktop.nix (per-user dispatch)
    Windows — this module

.PARAMETER Enabled
  When true, converge app tray icons to the registry. When false, skip.

.PARAMETER RepoRoot
  Path to the nucleus repository root (used to locate src/scripts/menu-bar.ps1).

.EXAMPLE
  Sync-MenuBar -Enabled:$true -RepoRoot $repoRoot
#>

function Sync-MenuBar {
  param(
    [switch]$Enabled,
    [string]$RepoRoot
  )

  if (-not $Enabled) { return }

  if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\..\..\")).Path
  }

  $menuBarScript = Join-Path -Path $RepoRoot -ChildPath "src\scripts\menu-bar.ps1"
  if (-not (Test-Path -LiteralPath $menuBarScript)) {
    Write-NucleusError -CommandName 'menu-bar' "script not found at $menuBarScript"
    return
  }

  try {
    & $menuBarScript apply
    if ($LASTEXITCODE -ne 0) {
      # The child script signals failure via exit code, not a thrown
      # exception; surface it as a hard error so convergence failure is never
      # silently swallowed (activation scripts must hard-error on failure).
      throw "menu-bar.ps1 exited with code $LASTEXITCODE"
    }
  } catch {
    Write-NucleusError -CommandName 'menu-bar' "menu-bar icon convergence failed: $($_.Exception.Message)"
    throw
  }
}
