<#
.SYNOPSIS
  Symlinks VS Code config files and directories to the live repo tree.

.DESCRIPTION
  Replaces VS Code's per-channel config files and directories with symlinks
  into the live repo tree (src/users/<user>/vscode/) so every VS Code write
  appears immediately as an unstaged git diff.

  Supersedes sync-vscodesettings.ps1, which used a managed-key merge that
  prevented VS Code from owning its own settings file.

.NOTES
  Environment variables: USERDOMAIN, USERNAME
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

    keybindings uses a host-specific repo source file (keybindings.Windows.json)
    so Windows shortcuts stay independent of the MacBook and NixOS files.
    chatLanguageModels.Windows.json is managed by a name-keyed merge
    (Merge-VSChatLanguageModel) instead of a symlink, so VS Code can write model
    updates back without breaking the repo link.

    Conflict handling applied to each item:
      Correct symlink   - no-op.
      Wrong symlink     - remove, create correct symlink.
      Real file or dir  - fail fast.
      Absent            - create symlink with parent directories as needed.

    Cleanup path (-Enabled:$false) removes every managed symlink pointing at our
    repo config dir; symlinks pointing elsewhere are left alone.

    Symlink creation requires either Developer Mode or an elevated session.

  .PARAMETER RepoRoot
    Absolute path to the repository root.

  .PARAMETER Enabled
    Create and validate symlinks when true, remove them when false.

  .PARAMETER Username
    User whose config overlay supplies the managed files. Defaults to the
    current user.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled,
    [Parameter()]
    [string]$Username = [System.Environment]::UserName
  )


  # WHY: the nested helpers read this through the enclosing scope, which hides the
  # read from PSReviewUnusedParameter; binding it locally keeps the data flow visible.
  $effectiveUsername = $Username

  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw 'Sync-VSCodeConfig: RepoRoot must not be empty.'
  }

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

  function Get-VSCodeRepoFileTarget {
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string]$User)
    return Resolve-UserConfigFile -User $User -ConfigName 'vscode' -RelativePath $RelativePath -RepoRoot $RepoRoot
  }

  function Get-VSCodeRepoDirTarget {
    param([Parameter(Mandatory)][string]$EntryName, [Parameter(Mandatory)][string]$User)
    return Resolve-UserConfigFirstLevelEntry -User $User -ConfigName 'vscode' -EntryName $EntryName -RepoRoot $RepoRoot
  }

  # Check Developer Mode once upfront so the failure names the missing privilege.
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

  # AppData\Roaming is resolved from the running session's profile; -Username
  # selects which user's config overlay supplies the managed files.
  $userProfile = [Environment]::GetFolderPath('UserProfile')
  $appDataRoaming = Join-Path -Path $userProfile -ChildPath "AppData\Roaming"

  # Both channels share one repo-backed config, so an edit in either appears in
  # the same git diff.
  $channelDirs = @(
    (Join-Path -Path $appDataRoaming -ChildPath "Code\User"),
    (Join-Path -Path $appDataRoaming -ChildPath "Code - Insiders\User")
  )

  $vscodeHostName = 'Windows'

  # Ordered hashtable of repo file name -> channel-side file name.
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

  # Ordered hashtable of repo dir alias -> channel-side relative path in User/.
  # WHY: copilot-memories gets a short repo alias because VS Code nests memories
  # under a long per-extension subpath that is awkward in a git tree.
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
      Replaces each destination object whose .name matches a repo object, appending
      repo objects with no match. Written back to $DestFile so VS Code-added model
      entries survive the next sync.
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
    Write-NucleusInfo -CommandName 'vscode-config' "merged chatLanguageModels from $RepoFile to $DestFile"
  }

  foreach ($channelDir in $channelDirs) {

    # --- Managed files ---
    foreach ($repoFileName in $managedFiles.Keys) {
      $linkFileName = $managedFiles[$repoFileName]
      $repoTarget = Get-VSCodeRepoFileTarget -RelativePath $repoFileName -User $effectiveUsername
      $linkPath   = Join-Path -Path $channelDir  -ChildPath $linkFileName

      if (-not $Enabled) {
        # A symlink pointing elsewhere was not created by us, so leave it alone.
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
            Remove-Item -LiteralPath $linkPath -Force
            Write-NucleusInfo -CommandName 'vscode-config' "removed VS Code config symlink: $linkPath"
          }
        }
        continue
      }

      if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath
        $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink: no-op.
        }

        if ($isSymlink) {
          # Wrong target (e.g. leftover from the old managed-key approach).
          Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          Write-NucleusError -CommandName 'vscode-config' "Sync-VSCodeConfig: $linkPath is not a managed symlink — merge any wanted content into $repoTarget and remove it, then re-run apply."
          return
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force > $null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget > $null
      Set-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
      Write-NucleusInfo -CommandName 'vscode-config' "linked VS Code config file: $linkPath -> $repoTarget"
    }

    # --- Managed directories ---
    foreach ($alias in $managedDirs.Keys) {
      $repoTarget = Get-VSCodeRepoDirTarget -EntryName $alias -User $effectiveUsername
      $linkPath   = Join-Path -Path $channelDir   -ChildPath $managedDirs[$alias]

      if (-not $Enabled) {
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
            Remove-Item -LiteralPath $linkPath -Force
            Write-NucleusInfo -CommandName 'vscode-config' "removed VS Code config dir symlink: $linkPath"
          }
        }
        continue
      }

      if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath
        $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
          continue  # Correct symlink: no-op.
        }

        if ($isSymlink) {
          Remove-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          Write-NucleusError -CommandName 'vscode-config' "Sync-VSCodeConfig: $linkPath is not a managed symlink — merge any wanted content into $repoTarget and remove it, then re-run apply."
          return
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force > $null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget > $null
      Set-ManagedSymlinkDeleteProtection -Context "vscode-config" -Path $linkPath
      Write-NucleusInfo -CommandName 'vscode-config' "linked VS Code config dir: $linkPath -> $repoTarget"
    }

    # --- chatLanguageModels (regular file, managed by merge) ---
    $chatLmPath = Join-Path -Path $channelDir -ChildPath "chatLanguageModels.json"
    if (-not $Enabled) {
      if (Test-Path -LiteralPath $chatLmPath) {
        Write-NucleusWarning -CommandName 'vscode-config' "chatLanguageModels.json at ${chatLmPath} was previously managed. Delete manually if no longer needed."
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
      $repoFile = Get-VSCodeRepoFileTarget -RelativePath "chatLanguageModels.$vscodeHostName.json" -User $effectiveUsername
      Merge-VSChatLanguageModel -RepoFile $repoFile -DestFile $chatLmPath
    }
  }
}
