# modules/windows/sync-nucleusvscodesettings.ps1 — VS Code settings parity helper.
#
# Converges managed settings keys across stable and insiders while preserving
# unmanaged user-defined keys.

function Sync-NucleusVsCodeSettings {
  <#
  .SYNOPSIS
    Converges managed VS Code user settings for stable and insiders channels.

  .DESCRIPTION
    Applies a shared set of managed settings keys to both:
      - %APPDATA%\Code\User\settings.json
      - %APPDATA%\Code - Insiders\User\settings.json

    When -Enabled:$false is passed, only managed keys are removed (cleanup
    path), preserving any unrelated user-defined settings. If a settings file
    becomes empty after cleanup, it is deleted.

  .PARAMETER Enabled
    Whether managed VS Code settings parity should be enforced. False triggers
    cleanup-only behavior.

  .EXAMPLE
    Sync-NucleusVsCodeSettings -Enabled:$true

  .EXAMPLE
    Sync-NucleusVsCodeSettings -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $managedSettings = [ordered]@{
    "editor.fontSize" = 14
    "nix.enableLanguageServer" = $true
    "rust-analyzer.check.command" = "clippy"
    "workbench.colorTheme" = "Default Dark Modern"
  }

  $settingsPaths = @(
    (Join-Path -Path $env:APPDATA -ChildPath "Code\User\settings.json"),
    (Join-Path -Path $env:APPDATA -ChildPath "Code - Insiders\User\settings.json")
  )

  foreach ($settingsPath in $settingsPaths) {
    $settingsDirectory = Split-Path -Path $settingsPath -Parent
    if ($Enabled -and -not (Test-Path -Path $settingsDirectory)) {
      New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    }

    $settingsObject = @{}
    if (Test-Path -Path $settingsPath) {
      $rawSettings = Get-Content -Path $settingsPath -Raw
      if (-not [string]::IsNullOrWhiteSpace($rawSettings)) {
        try {
          $parsedSettings = ConvertFrom-Json -InputObject $rawSettings -AsHashtable
          if ($null -ne $parsedSettings) {
            $settingsObject = $parsedSettings
          }
        }
        catch {
          throw "Failed to parse VS Code settings JSON at '$settingsPath'."
        }
      }
    }

    if ($Enabled) {
      foreach ($key in $managedSettings.Keys) {
        $settingsObject[$key] = $managedSettings[$key]
      }
    }
    else {
      foreach ($key in $managedSettings.Keys) {
        if ($settingsObject.ContainsKey($key)) {
          $settingsObject.Remove($key)
        }
      }
    }

    if ($settingsObject.Count -eq 0) {
      if (Test-Path -Path $settingsPath) {
        Remove-Item -Path $settingsPath -Force
      }

      continue
    }

    $settingsJson = ConvertTo-Json -InputObject $settingsObject -Depth 20
    [System.IO.File]::WriteAllText($settingsPath, "$settingsJson`r`n", [System.Text.UTF8Encoding]::new($false))
  }
}
