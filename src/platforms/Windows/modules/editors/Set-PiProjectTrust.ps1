<#
.SYNOPSIS
  Pre-trust shared directories in pi coding agent's project trust database.

.DESCRIPTION
  Reads the shared trust path list from src/scripts/editors/trust-paths.json and
  writes trust entries for each canonicalized path to %USERPROFILE%\.pi\agent\trust.json.
  Non-fatal on IO errors; warns to stderr so the operator is informed.

.NOTES
  Environment variables: HOME, USERPROFILE
  Exit codes: 0 on success; non-zero on failure (non-fatal warnings on stderr)
#>

function Set-PiProjectTrust {
<#
.SYNOPSIS
  Pre-trust shared directories in pi coding agent's project trust database.

.DESCRIPTION
  Pi coding agent stores project trust decisions in ~/.pi/agent/trust.json
  (Windows: %USERPROFILE%\.pi\agent\trust.json).  This function reads the
  shared trust path list from src/scripts/editors/trust-paths.json, expands
  ~ to $HOME, canonicalizes each path, and writes trust entries.

  The function is a no-op when:
    - Enabled is $false.
    - trust-paths.json is absent or contains no valid paths.
    - All trust entries are already present (idempotent re-apply).

  Non-fatal on IO errors; warns to stderr so the operator is informed but
  apply continues.

.PARAMETER Enabled
  When $false, skips the trust write without error.

.EXAMPLE
    Set-PiProjectTrust
  # Pre-trusts shared directories in pi's trust database.

.EXAMPLE
    Set-PiProjectTrust -Enabled:$false
  # No-op; skips all trust DB writes.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-NucleusInfo -CommandName 'pi-project-trust' "Set-PiProjectTrust: disabled; skipping"
        return
    }

    # Locate trust-paths.json via the repo root derived from $PSScriptRoot.
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $trustPathsFile = Join-Path -Path $repoRoot -ChildPath "src\scripts\editors\trust-paths.json"

    if (-not (Test-Path -Path $trustPathsFile)) {
        Write-NucleusWarning -CommandName 'pi-project-trust' "Set-PiProjectTrust: trust-paths.json not found at $trustPathsFile; skipping"
        return
    }

    # Read shared trust paths.
    $config = Get-Content -Raw -Path $trustPathsFile | ConvertFrom-Json
    $rawPaths = @($config.paths)

    if ($rawPaths.Count -eq 0) {
        return
    }

    # Trust file location.
    $trustDir = Join-Path -Path $HOME -ChildPath ".pi\agent"
    $trustPath = Join-Path -Path $trustDir -ChildPath "trust.json"

    # Read existing trust data (create if absent).
    $trustData = @{}
    if (Test-Path -Path $trustPath) {
        try {
            $existing = Get-Content -Raw -Path $trustPath | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) {
                if ($prop.Value -eq $true -or $prop.Value -eq $false) {
                    $trustData[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-NucleusWarning -CommandName 'pi-project-trust' "Set-PiProjectTrust: could not read $trustPath - $_"
        }
    }

    # Expand ~ and canonicalize each path.
    $added = $false
    foreach ($raw in $rawPaths) {
        $expanded = $raw -replace '^~', $HOME
        # Canonicalize via GetFullPath (mirrors pi's realpathSync).
        try {
            $canonical = [System.IO.Path]::GetFullPath($expanded)
        } catch {
            $canonical = $expanded
        }
        if (-not (Test-Path -Path $canonical -PathType Container)) {
            Write-NucleusInfo -CommandName 'pi-project-trust' "Set-PiProjectTrust: skipping $canonical (not a directory)"
            continue
        }
        if ($trustData[$canonical] -ne $true) {
            $trustData[$canonical] = $true
            $added = $true
        }
    }

    if (-not $added) {
        return
    }

    # Write back sorted JSON with 2-space indent and trailing newline.
    if ($PSCmdlet.ShouldProcess("pi trust database", "Set")) {
        try {
            if (-not (Test-Path -Path $trustDir)) {
                New-Item -Path $trustDir -ItemType Directory -Force | Out-Null
            }
            # Build sorted PSCustomObject for deterministic output.
            $sorted = [PSCustomObject]@{}
            foreach ($key in ($trustData.Keys | Sort-Object)) {
                $sorted | Add-Member -NotePropertyName $key -NotePropertyValue $trustData[$key]
            }
            $json = $sorted | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($trustPath, "$json`n", [System.Text.Encoding]::UTF8)
            Write-NucleusInfo -CommandName 'pi-project-trust' "Set-PiProjectTrust: trusted $($trustData.Count) path(s) in $trustPath"
        } catch {
            Write-NucleusWarning -CommandName 'pi-project-trust' "Set-PiProjectTrust: $trustPath - $_"
        }
    }
}
