# modules/windows/Set-VscodeWorkspaceTrust.ps1 — Pre-trust %USERPROFILE%\dev in VS Code workspace trust DB.
# Writes a trust entry for %USERPROFILE%\dev to the SQLite state.vscdb for
# both stable and insiders channels using Bun's built-in bun:sqlite module.
# Non-fatal when the DB is absent (VS Code not yet launched once) or locked
# (VS Code is currently running); warns to stderr so the operator is informed.

function Set-VscodeWorkspaceTrust {
<#
.SYNOPSIS
  Pre-trust %USERPROFILE%\dev in VS Code workspace trust for both stable and insiders channels.

.DESCRIPTION
  VS Code workspace trust state lives in a SQLite database (state.vscdb) inside
  each channel's globalStorage directory, not in settings.json.  This function
  writes the trust entry for the managed dev directory directly to that DB using
  Bun's built-in bun:sqlite module (Bun is already installed via WinGet).

  The function is a no-op when:
    - Enabled is $false.
    - %USERPROFILE%\dev does not exist (edge case: run before Provision-DevDirectory).
    - A DB path does not exist (VS Code channel not yet installed or never launched).
    - The trust entry is already present (idempotent re-apply).
    - bun is not found in PATH or ~/.bun/bin (warns and skips without error).

  Non-fatal when the DB is locked (VS Code running); the Bun script writes a
  warning to stderr so the operator is informed but apply continues.

.PARAMETER Enabled
  When $false, skips the trust write without error.  No cleanup path is needed
  because VS Code manages its own trust DB state; disabling this parameter
  simply stops updating the DB on future applies.

.EXAMPLE
  Set-VscodeWorkspaceTrust
  # Pre-trusts %USERPROFILE%\dev in both Code and Code - Insiders channels.

.EXAMPLE
  Set-VscodeWorkspaceTrust -Enabled:$false
  # No-op; skips all trust DB writes.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        Write-Output "vscode-workspace-trust: Set-VscodeWorkspaceTrust: disabled; skipping"
        return
    }

    $devPath = Join-Path -Path $HOME -ChildPath "dev"

    # Convert the Windows absolute path to VS Code's internal file URI path format.
    # VS Code encodes file URIs with a lowercase drive letter, a colon, and
    # forward slashes, preceded by a leading slash:
    #   C:\Users\user\dev  →  /c:/Users/user/dev
    $driveLetter = $devPath.Substring(0, 1).ToLower()
    $pathRest = $devPath.Substring(2).Replace('\', '/')
    $uriPath = "/$driveLetter`:$pathRest"

    # VS Code APPLICATION-scope storage (state.vscdb) lives in the globalStorage
    # subdirectory under each channel's User data directory.
    $appData = $env:APPDATA
    $dbPaths = @(
        (Join-Path -Path $appData -ChildPath "Code\User\globalStorage\state.vscdb"),
        (Join-Path -Path $appData -ChildPath "Code - Insiders\User\globalStorage\state.vscdb")
    )

    # Write the Bun/SQLite script to a temp file.  Single-quote here-string (@'...'@)
    # prevents PowerShell from expanding $-variables inside the script body;
    # the URI path and DB file paths are passed as CLI arguments instead so
    # the script body remains a literal and requires no escaping.
    $tempScript = [System.IO.Path]::GetTempFileName() + ".mjs"
    try {
        $scriptContent = @'
import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";

// argv[2] = uriPath to trust; argv[3+] = absolute paths to state.vscdb files.
const TRUST_KEY = "content.trust.model.key";
const uriPath = process.argv[2];
const dbPaths = process.argv.slice(3);

for (const dbPath of dbPaths) {
    if (!existsSync(dbPath)) continue;
    let db;
    try {
        db = new Database(dbPath, { readwrite: true });
        const row = db.query("SELECT value FROM ItemTable WHERE key = ?").get(TRUST_KEY);
        let data;
        if (row) {
            data = JSON.parse(row.value);
            const entries = data.uriTrustInfo ?? [];
            const alreadyTrusted = entries.some(
                e => e.uri?.path === uriPath && e.uri?.scheme === "file"
            );
            if (alreadyTrusted) {
                db.close();
                continue;
            }
            // Append the trust entry to the existing list rather than replacing
            // it so that any other paths the user has manually trusted are preserved.
            entries.push({ uri: { "$mid": 1, path: uriPath, scheme: "file" }, trusted: true });
            data.uriTrustInfo = entries;
        } else {
            data = { uriTrustInfo: [{ uri: { "$mid": 1, path: uriPath, scheme: "file" }, trusted: true }] };
        }
        db.run(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
            [TRUST_KEY, JSON.stringify(data)]
        );
        console.error("vscode-workspace-trust: Set-VscodeWorkspaceTrust: trusted", uriPath, "in", dbPath);
    } catch (e) {
        // Non-fatal: DB may be locked by a running VS Code instance.
        // Writing a warning so the operator knows to re-run apply after closing VS Code.
        console.error("vscode-workspace-trust: Set-VscodeWorkspaceTrust: warning:", dbPath, "-", e.message);
    } finally {
        if (db) db.close();
    }
}
'@
        [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)

        # Prepend ~/.bun/bin to PATH so bun is resolvable in this session even
        # if the user PATH has not been refreshed after WinGet installed Bun.
        $bunBin = Join-Path -Path $HOME -ChildPath ".bun\bin"
        if (Test-Path -Path (Join-Path -Path $bunBin -ChildPath "bun.exe")) {
            $env:PATH = "$bunBin;$env:PATH"
        }

        $bunCmd = Get-Command -Name "bun" -ErrorAction SilentlyContinue
        if ($null -eq $bunCmd) {
            Write-Warning "vscode-workspace-trust: Set-VscodeWorkspaceTrust: bun not found in PATH; skipping workspace trust write"
            return
        }

        # Pass uriPath and each DB path as positional arguments so the script
        # body contains no interpolated values and is safe to write as a literal.
        if ($PSCmdlet.ShouldProcess("VS Code workspace trust database", "Set")) {
            & $bunCmd.Source $tempScript $uriPath @dbPaths
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "vscode-workspace-trust: Set-VscodeWorkspaceTrust: bun script exited with code $LASTEXITCODE"
            }
        }
    }
    finally {
        if (Test-Path -Path $tempScript) {
            Remove-Item -Path $tempScript -Force
        }
    }
}
