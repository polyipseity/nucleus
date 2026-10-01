<#
.SYNOPSIS
  Pre-trust shared directories in VS Code workspace trust for both stable and insiders channels.

.DESCRIPTION
  Reads the shared trust path list from src/scripts/editors/trust-paths.json and
  writes trust entries for each path to the SQLite state.vscdb of both stable and
  insiders channels using Bun's built-in bun:sqlite module.

.NOTES
  Environment variables: APPDATA, HOME, PATH
#>

function Set-VSCodeWorkspaceTrust {
<#
.SYNOPSIS
  Pre-trust shared directories in VS Code workspace trust for both stable and insiders channels.

.DESCRIPTION
  WHY SQLite: VS Code workspace trust state lives in state.vscdb inside each
  channel's globalStorage directory, not in settings.json.

  A no-op when Enabled is $false, trust-paths.json is absent, a DB path does not
  exist (channel not yet installed or never launched), every entry is already
  present, or bun is missing. A locked DB warns to stderr and apply continues,
  since VS Code being open is not a convergence failure.

.PARAMETER Enabled
  When $false, skips the trust write without error.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-NucleusInfo -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: disabled; skipping"
        return
    }

    # repo root is four levels above src/platforms/Windows/modules/editors/
    # Module path: src/platforms/Windows/modules/editors/Set-VSCodeWorkspaceTrust.ps1
    # Repo root:   src/platforms/Windows/modules/editors/ → ../../../../
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $trustPathsFile = Join-Path -Path $repoRoot -ChildPath "src\scripts\editors\trust-paths.json"

    if (-not (Test-Path -Path $trustPathsFile)) {
        Write-NucleusWarning -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: trust-paths.json not found at $trustPathsFile; skipping"
        return
    }

    # APPLICATION-scope storage lives in globalStorage under each channel's User dir.
    $appData = $env:APPDATA
    $dbPaths = @(
        (Join-Path -Path $appData -ChildPath "Code\User\globalStorage\state.vscdb"),
        (Join-Path -Path $appData -ChildPath "Code - Insiders\User\globalStorage\state.vscdb")
    )

    # run the Bun/SQLite script from a temp file, keeping the body out of this wrapper
    $tempScript = [System.IO.Path]::GetTempFileName() + ".mjs"
    try {
        $scriptContent = Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\VSCode-workspace-trust.mjs")
        [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)

        # bun must resolve in this session even if the user PATH has not been
        # refreshed since WinGet installed Bun.
        # Canonical source: ManagedPaths.ps1 -> managed-paths.nix (pathComponents).
        $bunBin = Get-NucleusManagedBinDir "bun"
        if (Test-Path -Path (Join-Path -Path $bunBin -ChildPath "bun.exe")) {
            Add-NucleusPathEntry -Path $bunBin
        }

        $bunCmd = Get-Command -Name "bun" -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- bun may not be installed; $null check below handles absence
        if ($null -eq $bunCmd) {
            Write-NucleusWarning -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: bun not found in PATH; skipping workspace trust write"
            return
        }

        # trust-paths.json path, then each DB path, as positional arguments
        if ($PSCmdlet.ShouldProcess("VS Code workspace trust database", "Set")) {
            & $bunCmd.Source $tempScript $trustPathsFile @dbPaths
            if ($LASTEXITCODE -ne 0) {
                Write-NucleusWarning -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: bun script exited with code $LASTEXITCODE"
            }
        }
    }
    finally {
        if (Test-Path -Path $tempScript) {
            Remove-Item -Path $tempScript -Force
        }
    }
}
