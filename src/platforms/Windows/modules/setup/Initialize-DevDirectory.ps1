function Initialize-DevDirectory {
<#
.SYNOPSIS
  Create %USERPROFILE%\dev if absent.

.DESCRIPTION
  Create the managed dev root directory under the current user's home.
  Mirrors the MacBook ensure-dev-directory (macos.nix) and NixOS
  ensure-dev-directory (linux.nix) activations, which both create ~/dev
  unconditionally during activation.

  The function is idempotent: it is a no-op when the directory already exists.

.PARAMETER Enabled
  When $false, skips creation without error.

.EXAMPLE
  Initialize-DevDirectory
  # Creates %USERPROFILE%\dev if it does not already exist.

.EXAMPLE
  Initialize-DevDirectory -Enabled:$false
  # No-op; skips directory creation.

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-NucleusInfo -CommandName 'provision-devdirectory' "Initialize-DevDirectory: disabled; skipping"
        return
    }

    $devPath = Join-Path -Path $HOME -ChildPath "dev"
    if (-not (Test-Path -LiteralPath $devPath -PathType Container)) {
        New-Item -ItemType Directory -Path $devPath -Force > $null
        Write-NucleusInfo -CommandName 'provision-devdirectory' "created $devPath"
    } else {
        Write-NucleusInfo -CommandName 'provision-devdirectory' "$devPath already exists; skipping"
    }
}
