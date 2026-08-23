<#
.SYNOPSIS
  Converges GUI/user app auto-start to the apps.json registry on Windows.

.DESCRIPTION
  Registry-driven GUI app auto-start (replaces the inline Disable-SteamAutoStartup
  module).  Reads apps.json and converges every Windows app to its declared
  state via our uniform Run-key / Startup-folder mechanism, neutralizing any
  app-shipped native auto-start entry (e.g. Steam's Run key / Startup .lnk) so
  only our mechanism remains.

  Cross-platform parity:
    macOS   — login item removal in MacBook/activation.nix (osascript)
    NixOS   — activation script in desktop.nix (XDG .desktop removal)
    Windows — this module

.PARAMETER Enabled
  When true, converge app auto-start to the registry. When false, skip.

.PARAMETER RepoRoot
  Path to the nucleus repository root (used to locate src/scripts/autostart.ps1).

.EXAMPLE
  Sync-AppAutostart -Enabled:$true -RepoRoot $repoRoot
#>

function Sync-AppAutostart {
  param(
    [switch]$Enabled,
    [string]$RepoRoot
  )

  if (-not $Enabled) { return }

  if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\..\..\")).Path
  }

  $autostartScript = Join-Path -Path $RepoRoot -ChildPath "src\scripts\autostart.ps1"
  if (-not (Test-Path -LiteralPath $autostartScript)) {
    Write-NucleusError -CommandName 'autostart' "script not found at $autostartScript"
    return
  }

  try {
    & $autostartScript apply
    if ($LASTEXITCODE -ne 0) {
      # The child script signals failure via exit code, not a thrown
      # exception; surface it as a hard error so convergence failure is never
      # silently swallowed (activation scripts must hard-error on failure).
      throw "autostart.ps1 exited with code $LASTEXITCODE"
    }
  } catch {
    Write-NucleusError -CommandName 'autostart' "app auto-start convergence failed: $($_.Exception.Message)"
    throw
  }
}
