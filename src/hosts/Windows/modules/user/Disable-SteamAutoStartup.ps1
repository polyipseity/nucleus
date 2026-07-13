<#
.SYNOPSIS
  Removes Steam from Windows auto-startup mechanisms.

.DESCRIPTION
  Steam registers itself for auto-start via two mechanisms:
    1. Registry: HKCU\Software\Valve\Steam\AutoLoginUser
    2. Startup folder: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Steam.lnk
  This module removes both to disable Steam startup at logon.

  Cross-platform parity:
    macOS   — login item removal in MacBook/activation.nix (osascript)
    NixOS   — activation script in desktop.nix (autostart file removal)
    Windows — this module

.PARAMETER Enabled
  When true, remove Steam auto-startup entries. When false, skip.

.EXAMPLE
  Disable-SteamAutoStartup -Enabled:$true
#>

function Disable-SteamAutoStartup {
  param([switch]$Enabled)

  if (-not $Enabled) { return }

  # Remove registry value for auto-login.
  $steamRegPath = "HKCU:\Software\Valve\Steam"
  if (Test-Path -Path $steamRegPath) {
    # WHY: probe whether AutoLoginUser value exists (key exists but value may be absent).
    $autoLoginUser = Get-ItemProperty -Path $steamRegPath -Name "AutoLoginUser" -ErrorAction SilentlyContinue
    if ($null -ne $autoLoginUser) {
      Remove-ItemProperty -Path $steamRegPath -Name "AutoLoginUser" -ErrorAction SilentlyContinue
      Write-Output "steam: removed AutoLoginUser registry value"
    }
  }

  # Remove Steam from Startup folder.
  $startupPath = [Environment]::GetFolderPath("Startup")
  $steamShortcut = Join-Path -Path $startupPath -ChildPath "Steam.lnk"
  if (Test-Path -Path $steamShortcut) {
    Remove-Item -Path $steamShortcut -Force
    Write-Output "steam: removed Steam.lnk from Startup folder"
  }
}
