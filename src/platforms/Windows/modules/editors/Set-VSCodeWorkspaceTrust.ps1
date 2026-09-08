<#
.SYNOPSIS
  Pre-trust shared directories in VS Code workspace trust for both stable and insiders channels.

.DESCRIPTION
  Reads the shared trust path list from src/scripts/editors/trust-paths.json and
  writes trust entries for each path to the SQLite state.vscdb for both stable
  and insiders channels using Bun's built-in bun:sqlite module.
  Non-fatal when the DB is absent (VS Code not yet launched once) or locked
  (VS Code is currently running); warns to stderr so the operator is informed.

.NOTES
  Environment variables: APPDATA, HOME, PATH
  Exit codes: 0 on success; non-zero on failure (non-fatal warnings on stderr)
#>

function Set-VSCodeWorkspaceTrust {
<#
.SYNOPSIS
  Pre-trust shared directories in VS Code workspace trust for both stable and insiders channels.

.DESCRIPTION
  VS Code workspace trust state lives in a SQLite database (state.vscdb) inside
  each channel's globalStorage directory, not in settings.json.  This function
  reads the shared trust path list from src/scripts/editors/trust-paths.json and
  writes trust entries for each path directly to that DB using Bun's built-in
  bun:sqlite module (Bun is already installed via WinGet).

  The function is a no-op when:
    - Enabled is $false.
    - trust-paths.json is absent or contains no valid paths.
    - A DB path does not exist (VS Code channel not yet installed or never launched).
    - All trust entries are already present (idempotent re-apply).
    - bun is not found in PATH or ~/.bun/bin (warns and skips without error).

  Non-fatal when the DB is locked (VS Code running); the Bun script writes a
  warning to stderr so the operator is informed but apply continues.

.PARAMETER Enabled
  When $false, skips the trust write without error.  No cleanup path is needed
  because VS Code manages its own trust DB state; disabling this parameter
  simply stops updating the DB on future applies.

.EXAMPLE
    Set-VSCodeWorkspaceTrust
  # Pre-trusts shared directories in both Code and Code - Insiders channels.

.EXAMPLE
    Set-VSCodeWorkspaceTrust -Enabled:$false
  # No-op; skips all trust DB writes.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-NucleusInfo -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: disabled; skipping"
        return
    }

    # Locate trust-paths.json via the repo root derived from $PSScriptRoot.
    # Module path: src/platforms/Windows/modules/editors/Set-VSCodeWorkspaceTrust.ps1
    # Repo root:   src/platforms/Windows/modules/editors/ → ../../../../
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $trustPathsFile = Join-Path -Path $repoRoot -ChildPath "src\scripts\editors\trust-paths.json"

    if (-not (Test-Path -Path $trustPathsFile)) {
        Write-NucleusWarning -CommandName 'vscode-workspace-trust' "Set-VSCodeWorkspaceTrust: trust-paths.json not found at $trustPathsFile; skipping"
        return
    }

    # VS Code APPLICATION-scope storage (state.vscdb) lives in the globalStorage
    # subdirectory under each channel's User data directory.
    $appData = $env:APPDATA
    $dbPaths = @(
        (Join-Path -Path $appData -ChildPath "Code\User\globalStorage\state.vscdb"),
        (Join-Path -Path $appData -ChildPath "Code - Insiders\User\globalStorage\state.vscdb")
    )

    # Write the Bun/SQLite script to a temp file.  Read from the external
    # script file to keep the function body out of this wrapper.
    $tempScript = [System.IO.Path]::GetTempFileName() + ".mjs"
    try {
        $scriptContent = Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\VSCode-workspace-trust.mjs")
        [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)

        # Prepend ~/.bun/bin to PATH so bun is resolvable in this session even
        # if the user PATH has not been refreshed after WinGet installed Bun.
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

        # Pass trust-paths.json path and each DB path as positional arguments.
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
