<#
.SYNOPSIS
  Symlinks VS Code config files and directories to the live repo tree.

.DESCRIPTION
  Replaces VS Code's per-channel config files and directories with symlinks
  into the live repo tree (src/users/<user>/vscode/) so every VS Code write
  appears immediately as an unstaged git diff rather than being silently managed
  away by a deployment layer.

  Supersedes sync-vscodesettings.ps1, which used a managed-key merge
  approach that prevented VS Code from owning its own settings file.  The
  symlink approach gives the repo complete, transparent ownership of all VS
  Code config while still allowing VS Code to write through the link freely.

.NOTES
  Environment variables: USERDOMAIN, USERNAME
  Exit codes: 0 on success; non-zero on failure
#>

function Sync-VSCodeConfig {
  <#
  .SYNOPSIS
    Symlinks VS Code config files and directories to the live repo tree.

  .DESCRIPTION
    For each managed item (chatLanguageModels.json, keybindings.json, mcp.json,
    settings.json, tasks.json, and the snippets/, prompts/, profiles/, and
    copilot-memories/ directories) and for both the stable (Code) and insiders
    (Code - Insiders) channels, creates a symlink from the VS Code User data
    directory into $RepoRoot\src\modules\configs\vscode\.

    keybindings uses a host-specific repo source file
    (keybindings.Windows.json) so that Windows key shortcuts are tracked
    independently from MacBook (keybindings.MacBook.json) and NixOS
    (keybindings.NixOS.json) without cross-host pollution in a shared file.
    chatLanguageModels.Windows.json is managed by a name-keyed merge-overwrite
    (Merge-VSChatLanguageModel) instead of a symlink, so that VS Code can
    write model updates back without breaking the repo link.

    Conflict handling applied to each item:
      Correct symlink     — no-op.
      Wrong symlink       — remove, create correct symlink.
      Real file or dir    — fail fast (merge wanted content into the repo
                            target and remove the conflict, then re-run apply).
      Absent              — create symlink (parent directories created as
                            needed).

    Cleanup path (-Enabled:$false): removes every managed symlink that points
    to our repo config dir; VS Code recreates plain files on next launch.
    Symlinks not pointing to our config dir are left untouched.

    Symlink creation on Windows requires either Developer Mode or an elevated
    session.

  .PARAMETER RepoRoot
    Absolute path to the repository root.  Mandatory: passed explicitly so the
    function does not re-derive the repo from the working directory and to
    ensure callers are aware of which repository will be modified.

  .PARAMETER Enabled
    Whether VS Code config symlinks should be managed. Mandatory: caller must
    explicitly choose true (create/validate symlinks) or false (remove managed
    symlinks). No implicit default is permitted.

  .PARAMETER Username
    Username for which VS Code config is being managed. Explicitly passed to
    ensure caller is aware of which user's profile will be modified. Defaults to
    the current user if omitted, but the parameter must be present in the
    signature to force awareness of user context.

  .OUTPUTS
    None.  Writes informational messages to the host output stream.

  .EXAMPLE
    Sync-VSCodeConfig -RepoRoot "C:\Users\admin\nucleus" -Enabled:$true -Username 'admin'

  .EXAMPLE
    Sync-VSCodeConfig -RepoRoot "C:\Users\admin\nucleus" -Enabled:$false -Username 'guest'
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled,
    [Parameter()]
    [string]$Username = [System.Environment]::UserName
  )


  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw 'Sync-VSCodeConfig: RepoRoot must not be empty.'
  }

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

  function Get-VSCodeRepoFileTarget {
    param([Parameter(Mandatory)][string]$RelativePath)
    return Resolve-UserConfigFile -User $Username -ConfigName 'vscode' -RelativePath $RelativePath -RepoRoot $RepoRoot
  }

  function Get-VSCodeRepoDirTarget {
    param([Parameter(Mandatory)][string]$EntryName)
    return Resolve-UserConfigFirstLevelEntry -User $Username -ConfigName 'vscode' -EntryName $EntryName -RepoRoot $RepoRoot
  }

  # Symlinks on Windows require Developer Mode or an elevated session.  Check
  # once upfront so the failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    # check-suppress:suppression_doc: probe whether Developer Mode is already enabled; Get-ItemProperty throws when value is absent.
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- registry value may not exist; $null check below handles absence
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      throw "Sync-VSCodeConfig requires Developer Mode or an elevated session to create symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
    }
  }

  # Build the target user's AppData\Roaming root from the explicit Username
  # parameter so callers control which profile receives managed VS Code
  # symlinks.
  $userProfile = Join-Path -Path "C:\Users" -ChildPath $Username
  $appDataRoaming = Join-Path -Path $userProfile -ChildPath "AppData\Roaming"

  # Both stable and insiders channels share the same repo-backed config so
  # edits in either channel appear in the same git diff.
  $channelDirs = @(
    (Join-Path -Path $appDataRoaming -ChildPath "Code\User"),
    (Join-Path -Path $appDataRoaming -ChildPath "Code - Insiders\User")
  )

  $vscodeHostName = 'Windows'

  # Managed single files: ordered hashtable of repo file name -> channel-side
  # file name.  chatLanguageModels is managed separately via
  # Merge-VSChatLanguageModel (name-keyed merge, not a symlink).
  $managedFiles = [ordered]@{
    # check-suppress:config-method: method 1 (writable symlink) -- VS Code reads its keybindings from a known path
    "keybindings.$vscodeHostName.json" = "keybindings.json"
    # check-suppress:config-method: method 1 (writable symlink) -- read by Copilot MCP extension
    "mcp.json"                        = "mcp.json"
    # check-suppress:config-method: method 1 (writable symlink) -- VS Code reads settings on startup
    "settings.json"                   = "settings.json"
    # check-suppress:config-method: method 1 (writable symlink) -- VS Code task definitions
    "tasks.json"                      = "tasks.json"
  }

  # Managed directories: ordered hashtable of repo dir alias -> channel-side
  # relative path inside the User/ data directory.  copilot-memories uses a
  # short repo alias because VS Code stores memories under a long per-extension
  # subpath that is inconvenient to navigate in a git tree.
  $managedDirs = [ordered]@{
    "copilot-memories" = "globalStorage\github.copilot-chat\memory-tool\memories"
    "profiles"         = "profiles"
    "prompts"          = "prompts"
    "snippets"         = "snippets"
  }

  function Merge-VSChatLanguageModel {
    <#
    .SYNOPSIS
      Name-keyed merge-overwrite of chatLanguageModels from repo source to VS Code dest.

    .DESCRIPTION
      Reads the repo source and destination JSON arrays, then for each object in the
      repo source, replaces a destination object with the same .name (or appends if
      not found).  Written back to $DestFile so VS Code can save new model entries
      that survive the next sync.
    #>
    param(
      [Parameter(Mandatory)]
      [string]$RepoFile,
      [Parameter(Mandatory)]
      [string]$DestFile
    )

    $repoContent = Get-Content -LiteralPath $RepoFile -Raw | ConvertFrom-Json
    $existingContent = @()
    if (Test-Path -LiteralPath $DestFile -PathType Leaf) {
      $raw = Get-Content -LiteralPath $DestFile -Raw -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- guarded by Test-Path above; race-condition guard for file deleted between check and read
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $existingContent = $raw | ConvertFrom-Json
      }
    }

    $existing = [System.Collections.ArrayList]::new($existingContent)

    foreach ($repoItem in $repoContent) {
      $match = $existing | Where-Object { $_.name -eq $repoItem.name } | Select-Object -First 1
      if ($null -ne $match) {
        $idx = $existing.IndexOf($match)
        if ($idx -ge 0) {
          $existing[$idx] = $repoItem
        }
      } else {
        $null = $existing.Add($repoItem)  # check-suppress:suppression_doc: Add returns collection count, discarded
      }
    }

    $json = $existing | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $DestFile -Value $json -Encoding UTF8 -NoNewline
    Write-Output "vscode-config: merged chatLanguageModels from $RepoFile to $DestFile"
  }

  foreach ($channelDir in $channelDirs) {

    # --- Managed files ---
    foreach ($repoFileName in $managedFiles.Keys) {
      $linkFileName = $managedFiles[$repoFileName]
      $repoTarget = Get-VSCodeRepoFileTarget -RelativePath $repoFileName
      $linkPath   = Join-Path -Path $channelDir  -ChildPath $linkFileName

      if (-not $Enabled) {
        # Cleanup: remove the symlink only when it points to our repo target.
        # A symlink pointing elsewhere was not created by us and must not be
        # disturbed.
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
            Remove-Item -LiteralPath $linkPath -Force
            Write-Output "vscode-config: removed VS Code config symlink: $linkPath"
          }
        }
        continue
      }

      if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath
        $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }

        if ($isSymlink) {
          # Wrong symlink target (e.g. leftover from old managed-key approach).
          # Remove and recreate pointing to the repo.
          Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          Write-Error "vscode-config: Sync-VSCodeConfig: $linkPath is not a managed symlink — merge any wanted content into $repoTarget and remove it, then re-run apply."
          return
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force > $null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget > $null
      Set-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
      Write-Output "vscode-config: linked VS Code config file: $linkPath -> $repoTarget"
    }

    # --- Managed directories ---
    foreach ($alias in $managedDirs.Keys) {
      $repoTarget = Get-VSCodeRepoDirTarget -EntryName $alias
      $linkPath   = Join-Path -Path $channelDir   -ChildPath $managedDirs[$alias]

      if (-not $Enabled) {
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
            Remove-Item -LiteralPath $linkPath -Force
            Write-Output "vscode-config: removed VS Code config dir symlink: $linkPath"
          }
        }
        continue
      }

      if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath
        $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink — no-op.
        }

        if ($isSymlink) {
          Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          Write-Error "vscode-config: Sync-VSCodeConfig: $linkPath is not a managed symlink — merge any wanted content into $repoTarget and remove it, then re-run apply."
          return
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force > $null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget > $null
      Set-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
      Write-Output "vscode-config: linked VS Code config dir: $linkPath -> $repoTarget"
    }

    # --- chatLanguageModels (regular file, managed by merge) ---
    $chatLmPath = Join-Path -Path $channelDir -ChildPath "chatLanguageModels.json"
    if (-not $Enabled) {
      if (Test-Path -LiteralPath $chatLmPath) {
        Write-Warning "vscode-config: chatLanguageModels.json at ${chatLmPath} was previously managed. Delete manually if no longer needed."
      }
    } else {
      # Remove any old symlink before merge so Set-Content writes a regular file.
      if (Test-Path -LiteralPath $chatLmPath) {
        $item = Get-Item -LiteralPath $chatLmPath
        $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isSymlink) {
          Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $chatLmPath -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup -- symlink may already be removed or never existed; best-effort cleanup before recreation
          Remove-Item -LiteralPath $chatLmPath -Force
        }
      }
      # check-suppress:config-method: method 3 (merge) -- name-keyed merge preserves VS Code-added model entries while refreshing repo entries.
      $repoFile = Get-VSCodeRepoFileTarget -RelativePath "chatLanguageModels.$vscodeHostName.json"
      Merge-VSChatLanguageModel -RepoFile $repoFile -DestFile $chatLmPath
    }
  }
}
