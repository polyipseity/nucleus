# modules/windows/editors.ps1 — Windows editor parity helpers.
#
# Maintains VS Code user settings parity for stable and insiders channels using
# the same shared key set declared for POSIX hosts.

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
        Remove-Item -Path $settingsPath -Force -ErrorAction SilentlyContinue
      }

      continue
    }

    $settingsJson = ConvertTo-Json -InputObject $settingsObject -Depth 20
    [System.IO.File]::WriteAllText($settingsPath, "$settingsJson`r`n", [System.Text.UTF8Encoding]::new($false))
  }
}

function Sync-NucleusVsCodeExtensions {
  <#
  .SYNOPSIS
    Converges managed VS Code extension parity for stable and insiders.

  .DESCRIPTION
    Installs or removes a managed extension set on both `code` and
    `code-insiders` CLIs when available. Missing CLIs are treated as a warning
    so bootstrap can proceed before first app launch PATH updates settle.

    Cleanup behavior when disabled removes only managed extensions.

  .PARAMETER Enabled
    Whether managed extension parity should be enforced. False removes the
    managed extensions from discovered VS Code channels.

  .EXAMPLE
    Sync-NucleusVsCodeExtensions -Enabled:$true

  .EXAMPLE
    Sync-NucleusVsCodeExtensions -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $managedExtensions = @(
    'jnoortheen.nix-ide',
    'rust-lang.rust-analyzer',
    'tamasfe.even-better-toml'
  )

  $channels = @(
    @{ Name = 'stable'; Command = 'code' },
    @{ Name = 'insiders'; Command = 'code-insiders' }
  )

  foreach ($channel in $channels) {
    $cliPath = Get-Command -Name $channel.Command -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($cliPath)) {
      Write-Host "Skipping VS Code $($channel.Name) extension sync: '$($channel.Command)' not found in PATH." -ForegroundColor Yellow
      continue
    }

    foreach ($extensionId in $managedExtensions) {
      if ($Enabled) {
        & $cliPath --install-extension $extensionId --force *> $null
      }
      else {
        & $cliPath --uninstall-extension $extensionId *> $null
      }
    }
  }
}
