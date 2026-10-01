<#
.SYNOPSIS
  Pre-trust shared directories in pi coding agent's project trust database.

.DESCRIPTION
  Reads the shared trust path list from src/scripts/editors/trust-paths.json and
  writes trust entries for each canonicalized path to
  %USERPROFILE%\.pi\agent\trust.json. IO errors are non-fatal.

.NOTES
  Environment variables: HOME, USERPROFILE
#>

function Set-PiProjectTrust {
<#
.SYNOPSIS
  Pre-trust shared directories in pi coding agent's project trust database.

.DESCRIPTION
  Pi stores project trust decisions in ~/.pi/agent/trust.json (Windows:
  %USERPROFILE%\.pi\agent\trust.json). This function reads the shared trust
  path list from src/scripts/editors/trust-paths.json, expands ~ to $HOME,
  canonicalizes each path, and writes the entries.

  A no-op when Enabled is $false, trust-paths.json is absent or lists no valid
  paths, or every entry is already present. IO errors warn and let apply continue.

.PARAMETER Enabled
  When $false, skips the trust write without error.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-NucleusInfo -CommandName 'pi-project-trust' "Set-PiProjectTrust: disabled; skipping"
        return
    }

    # repo root is four levels above src/platforms/Windows/modules/editors/
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

    $trustDir = Join-Path -Path $HOME -ChildPath ".pi\agent"
    $trustPath = Join-Path -Path $trustDir -ChildPath "trust.json"

    # existing entries, empty when the file is absent
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

    # expand ~ and canonicalize
    $added = $false
    foreach ($raw in $rawPaths) {
        $expanded = $raw -replace '^~', $HOME
        # WHY: GetFullPath mirrors pi's realpathSync, so both agree on the key.
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

    # sorted JSON with 2-space indent and a trailing newline
    if ($PSCmdlet.ShouldProcess("pi trust database", "Set")) {
        try {
            if (-not (Test-Path -Path $trustDir)) {
                New-Item -Path $trustDir -ItemType Directory -Force > $null
            }
            # sorted output is deterministic
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
