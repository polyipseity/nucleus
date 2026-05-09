# modules/windows/sync-vscodeconfig.ps1 — VS Code git-backed config symlinks.
#
# Replaces VS Code's per-channel config files and directories with symlinks
# into the live repo tree (src/modules/configs/vscode/) so every VS Code write
# appears immediately as an unstaged git diff rather than being silently managed
# away by a deployment layer.
#
# Supersedes sync-vscodesettings.ps1, which used a managed-key merge
# approach that prevented VS Code from owning its own settings file.  The
# symlink approach gives the repo complete, transparent ownership of all VS
# Code config while still allowing VS Code to write through the link freely.

function Sync-VscodeConfig {
  <#
  .SYNOPSIS
    Symlinks VS Code config files and directories to the live repo tree.

  .DESCRIPTION
    For each managed item (chatLanguageModels.json, keybindings.json, mcp.json,
    settings.json, tasks.json, and the snippets/, prompts/, profiles/, and
    copilot-memories/ directories) and for both the stable (Code) and insiders
    (Code - Insiders) channels, creates a symlink from the VS Code User data
    directory into $RepoRoot\src\modules\configs\vscode\.

    Both chatLanguageModels and keybindings use Windows-specific repo source
    files (chatLanguageModels.windows.json and keybindings.windows.json) so
    that Windows model budgets (Ctrl-key shortcuts) are tracked independently
    from macOS (chatLanguageModels.mac.json / keybindings.mac.json) and NixOS
    (chatLanguageModels.nixos.json / keybindings.nixos.json) without
    cross-host pollution in a shared file.

    Migration safety applied to each item:
      Correct symlink     — no-op.
      Wrong symlink       — remove, create correct symlink.  Handles the
                            transition from the old managed-key settings file.
      Real non-empty file — copy content to the repo target when the repo
                            target is absent or empty (preserves any pre-existing
                            VS Code edits), then replace with symlink.
      Real non-empty dir  — copy each top-level file to the repo dir without
                            overwriting existing content (repo is source of
                            truth), then replace the directory with a symlink.
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
    Sync-VscodeConfig -RepoRoot "C:\Users\admin\nucleus" -Enabled:$true -Username 'admin'

  .EXAMPLE
    Sync-VscodeConfig -RepoRoot "C:\Users\admin\nucleus" -Enabled:$false -Username 'guest'
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [Parameter(Mandatory)]
    [bool]$Enabled,
    [Parameter()]
    [string]$Username = [System.Environment]::UserName
  )

  $vsConfigDir = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\vscode"
  if ($Enabled -and -not (Test-Path -LiteralPath $vsConfigDir -PathType Container)) {
    throw "VS Code config directory not found: $vsConfigDir"
  }

  # Symlinks on Windows require Developer Mode or an elevated session.  Check
  # once upfront so the failure message is actionable rather than cryptic.
  if ($Enabled) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $devModeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    $devModeProp = Get-ItemProperty -Path $devModeKey -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
    $devModeEnabled = $null -ne $devModeProp -and $devModeProp.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $isAdmin -and -not $devModeEnabled) {
      throw "Sync-VscodeConfig requires Developer Mode or an elevated session to create symlinks.  Enable Developer Mode in Settings -> System -> For Developers."
    }
  }

  # Both stable and insiders channels share the same repo-backed config so
  # edits in either channel appear in the same git diff.
  $channelDirs = @(
    (Join-Path -Path $env:APPDATA -ChildPath "Code\User"),
    (Join-Path -Path $env:APPDATA -ChildPath "Code - Insiders\User")
  )

  # Managed single files: ordered hashtable of repo file name -> channel-side
  # file name.  Per-host chatLanguageModels and keybindings use Windows-specific
  # repo sources so that each host's model budget and key shortcuts are tracked
  # independently without cross-host pollution.
  $managedFiles = [ordered]@{
    "chatLanguageModels.windows.json" = "chatLanguageModels.json"
    "keybindings.windows.json"        = "keybindings.json"
    "mcp.json"                        = "mcp.json"
    "settings.json"                   = "settings.json"
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

  foreach ($channelDir in $channelDirs) {

    # --- Managed files ---
    foreach ($repoFileName in $managedFiles.Keys) {
      $linkFileName = $managedFiles[$repoFileName]
      $repoTarget = Join-Path -Path $vsConfigDir -ChildPath $repoFileName
      $linkPath   = Join-Path -Path $channelDir  -ChildPath $linkFileName

      if (-not $Enabled) {
        # Cleanup: remove the symlink only when it points to our repo target.
        # A symlink pointing elsewhere was not created by us and must not be
        # disturbed.
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
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
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          # Real file: migrate content to repo target when the repo target does
          # not yet contain meaningful content so pre-existing VS Code edits are
          # not silently discarded on first activation.
          $repoContent = $null
          if (Test-Path -LiteralPath $repoTarget) {
            $repoContent = Get-Content -LiteralPath $repoTarget -Raw -ErrorAction SilentlyContinue
          }
          if ([string]::IsNullOrEmpty($repoContent)) {
            Copy-Item -LiteralPath $linkPath -Destination $repoTarget -Force
          }
          Remove-Item -LiteralPath $linkPath -Force
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget | Out-Null
      Write-Output "vscode-config: linked VS Code config file: $linkPath -> $repoTarget"
    }

    # --- Managed directories ---
    foreach ($alias in $managedDirs.Keys) {
      $repoTarget = Join-Path -Path $vsConfigDir  -ChildPath $alias
      $linkPath   = Join-Path -Path $channelDir   -ChildPath $managedDirs[$alias]

      if (-not $Enabled) {
        if (Test-Path -LiteralPath $linkPath) {
          $item = Get-Item -LiteralPath $linkPath
          $isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
          if ($isSymlink -and [string]::Equals($item.Target, $repoTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
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
          Remove-Item -LiteralPath $linkPath -Force
        } else {
          # Real directory: copy each top-level file to the repo dir without
          # overwriting existing repo content; repo is the source of truth.
          Get-ChildItem -LiteralPath $linkPath -File -ErrorAction SilentlyContinue | ForEach-Object {
            $destFile = Join-Path -Path $repoTarget -ChildPath $_.Name
            if (-not (Test-Path -LiteralPath $destFile)) {
              Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force
            }
          }
          Remove-Item -LiteralPath $linkPath -Recurse -Force
        }
      }

      $parentDir = Split-Path -Path $linkPath -Parent
      if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
      }
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $repoTarget | Out-Null
      Write-Output "vscode-config: linked VS Code config dir: $linkPath -> $repoTarget"
    }
  }
}
