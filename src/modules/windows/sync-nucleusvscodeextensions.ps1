# modules/windows/sync-nucleusvscodeextensions.ps1 — VS Code extension parity helper.
#
# Converges a managed extension baseline across stable and insiders channels
# without touching unmanaged extension installs.

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
