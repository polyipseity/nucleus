<#
.SYNOPSIS
  Trust Caddy local CA for managed localhost HTTPS ingress.

.DESCRIPTION
  Ensures the local machine trusts certificates issued by Caddy's internal PKI
  authority served by the admin endpoint (127.0.0.1:2019). This trust is shared
  across any managed localhost reverse proxies using `tls internal`, not just
  Jellyfin.

  Source:
  - https://caddyserver.com/docs/command-line#caddy-trust

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This module does not emit exit codes.
#>
function Sync-CaddyLocalCA {
  <#
  .SYNOPSIS
    Trusts Caddy's local CA root certificate from the admin API.

  .DESCRIPTION
    Runs `caddy trust --address 127.0.0.1:2019` with bounded retries so apply
    can converge trust after Caddy-backed localhost HTTPS ingress services come
    online.

    The operation is best-effort and intentionally non-fatal: a trust failure
    should not roll back an otherwise successful system apply.

  .PARAMETER RepoRoot
    Absolute path to the repository root. Required for explicit caller context.

  .PARAMETER Enabled
    Whether local CA trust convergence should be attempted.

  .EXAMPLE
    Sync-CaddyLocalCA -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot does not exist: $RepoRoot"
  }

  if (-not $Enabled) {
    return
  }

  # undoc-supp: probe whether caddy binary is installed; Get-Command throws when absent.
  $caddyCommand = Get-Command -Name 'caddy.exe' -ErrorAction SilentlyContinue
  if ($null -eq $caddyCommand) {
    # undoc-supp: fallback probe without .exe suffix for non-Windows or WSL scenarios.
    $caddyCommand = Get-Command -Name 'caddy' -ErrorAction SilentlyContinue
  }

  if ($null -eq $caddyCommand) {
    Write-Warning 'caddy-trust: caddy binary not found in PATH; skipping local CA trust convergence.'
    return
  }

  # undoc-supp: probe — services.json may not exist yet; $null check handles absence.
  $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
  $adminAddr = if ($svc.caddy.network.admin) { "$($svc.caddy.network.admin.host):$($svc.caddy.network.admin.port)" } else { '127.0.0.1:2019' }

  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
      & $caddyCommand.Source trust --address $adminAddr | Out-Null
      Write-Output 'caddy-trust: local CA trusted successfully.'
      return
    }
    catch {
      if ($attempt -eq 20) {
        Write-Warning "caddy-trust: failed to trust local CA from $adminAddr after $attempt attempts: $($_.Exception.Message)"
        return
      }
      Start-Sleep -Seconds 1
    }
  }
}
