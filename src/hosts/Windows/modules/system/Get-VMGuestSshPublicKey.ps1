function Get-VmGuestSshPublicKey {
    <#
    .SYNOPSIS
      Resolves the host SSH public key for NixOS guest authorized_keys injection.

    .DESCRIPTION
      Reads src/modules/vm-guest-ssh-public-key-paths.json and returns the first
      readable public key under ~/.ssh. Static id_*.pub paths are tried before
      username-scoped nucleus keys (ssh_personal_{username}.pub).

    .PARAMETER RepoRoot
      Absolute path to the repository root.

    .PARAMETER Username
      Resolved VM guest username from SOPS. When empty, username templates are skipped.

    .OUTPUTS
      System.String when a key is found; otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$Username = ''
    )

    $manifestPath = Join-Path $RepoRoot 'src\modules\vm-guest-ssh-public-key-paths.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "vm-setup: guest SSH public key manifest not found: $manifestPath"
    }

    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Test-Path -LiteralPath $sshDir -PathType Container)) {
        return $null
    }

    foreach ($relativePath in @($manifest.staticRelativePaths)) {
        $keyPath = Join-Path $sshDir $relativePath
        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            try {
                return (Get-Content -Path $keyPath -Raw).Trim()
            } catch {
                continue
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        foreach ($template in @($manifest.usernameRelativePathTemplates)) {
            $relativePath = $template -replace '\{username\}', $Username
            $keyPath = Join-Path $sshDir $relativePath
            if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
                try {
                    return (Get-Content -Path $keyPath -Raw).Trim()
                } catch {
                    continue
                }
            }
        }
    }

    return $null
}
