# modules/windows/provision-devdirectory.ps1 — Create %USERPROFILE%\dev when absent.
# Mirrors the macOS configureSystemHardening and NixOS provisionDevDirectory
# activations that create ~/dev on all POSIX hosts.

function Initialize-DevDirectory {
<#
.SYNOPSIS
  Create %USERPROFILE%\dev if absent.

.DESCRIPTION
  Ensures the managed dev root directory exists under the current user's home.
  Mirrors macOS configureSystemHardening (macos.nix) and NixOS
  provisionDevDirectory (linux.nix), which both create ~/dev unconditionally
  during activation.

  The function is idempotent: it is a no-op when the directory already exists.

.PARAMETER Enabled
  When $false, skips creation without error.

.EXAMPLE
  Initialize-DevDirectory
  # Creates %USERPROFILE%\dev if it does not already exist.

.EXAMPLE
  Initialize-DevDirectory -Enabled:$false
  # No-op; skips directory creation.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-Output "provision-devdirectory: Initialize-DevDirectory: disabled; skipping"
        return
    }

    $devPath = Join-Path -Path $HOME -ChildPath "dev"
    if (-not (Test-Path -LiteralPath $devPath -PathType Container)) {
        New-Item -ItemType Directory -Path $devPath -Force | Out-Null
        Write-Output "provision-devdirectory: created $devPath"
    } else {
        Write-Output "provision-devdirectory: $devPath already exists; skipping"
    }
}
