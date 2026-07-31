function Sync-ShellProfile {
  <#
  .SYNOPSIS
    Converges a managed shell-parity block in PowerShell profile files.

  .DESCRIPTION
    Writes or removes a bounded managed block in:
      - CurrentUserCurrentHost profile
      - CurrentUserAllHosts profile

    Managed content is read from the shared cross-platform profile
    src/scripts/shell/profile.ps1 (single source of truth; also embedded by
    src/modules/pwsh.nix on POSIX hosts) and substituted into the managed
    block, intentionally mirroring key POSIX shell workflow behavior:
      - direnv integration (if direnv is present)
      - PSReadLine predictive history completion and menu-style tab expansion
        (if PSReadLine module is available; bundled with pwsh on all supported hosts)
      - zoxide smart directory navigation (if zoxide is present)
      - fzf Ctrl+R fuzzy history search via PSReadLine key handler
        (if fzf is present and PSReadLine is available)
      - pay-respects command correction hook (if pay-respects is present; installed
        via cargo-binstall by Invoke-CargoBinstallSetup)
      - common aliases (`-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gl`, `-gp`,
        `-gpl`, `-gs-pdf-opt-*` (Ghostscript PDF presets), `-gsw`, `-gst`, `-la`, `-ll` (eza preferred, Get-ChildItem fallback),
        `-ni`, `-nr`, `-nx` (bun shortcuts, if bun present), `-v`)
      - Python ban: blocks system-wide python/pip to prevent accidental
         modifications to system environment
      - Build tool ban: blocks system-wide bun/cargo/rustc/uv direct invocation;
        passes through when DIRENV_DIR is set (active direnv/devShell context)
        or when the managed default dev environment is active for repositories
        that do not ship direnv/Nix metadata

    Cleanup behavior when disabled removes only the managed block.

  .PARAMETER Enabled
    Whether managed shell parity should be enforced. Mandatory: caller must
    explicitly choose true (apply) or false (cleanup). False removes the managed
    block from profile files.

  .EXAMPLE
    Sync-ShellProfile -Enabled:$true

  .EXAMPLE
    Sync-ShellProfile -Enabled:$false

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $managedBlockStart = '# >>> config managed shell parity >>>'
  $managedBlockEnd = '# <<< config managed shell parity <<<'
  # User-scope package manager bin directories are prepended before the
  # direnv hook initializes so they are always part of the environment
  # direnv saves and restores, regardless of whether the directories
  # existed at profile load time.  No existence guard: non-existent dirs
  # in PATH are harmless and the unconditional add ensures a new terminal
  # opened after apply sees the correct PATH immediately.
  # Sources: ManagedPaths.ps1 -> managed-paths.nix (pathComponents.append).
  # Compute from the canonical path list so additions only need updating in
  # one place.  Each entry (e.g. '.bun\bin') produces a variable definition,
  # a guard, and a PATH assignment.
  $prependLines = $nucleusPathComponents.Prepend | ForEach-Object {
    $__binName = $_ -replace '^\.(.+)\\bin$', '$1'
    $__binVar  = "${__binName}BinDir"
    "`$$__binVar = Join-Path `$env:USERPROFILE `"$_`""
    "if (`$env:PATH -notlike `"*`$$__binVar*`") {"
    "  `$env:PATH = `"`$$__binVar;`$env:PATH`""
    "}"
  }

  $appendLines = $nucleusPathComponents.Append | ForEach-Object {
    $__binName = $_ -replace '^\.(.+)\\bin$', '$1'
    $__binVar  = "${__binName}BinDir"
    "`$$__binVar = Join-Path `$env:USERPROFILE `"$_`""
    "if (`$env:PATH -notlike `"*`$$__binVar*`") {"
    "  `$env:PATH = `"`$env:PATH;`$$__binVar`""
    "}"
  }

  # Managed block content lives in the shared cross-platform profile at
  # src/scripts/shell/profile.ps1.  Read it back here and substitute the three
  # platform-specific tokens so shell-parity content has a single source of
  # truth: the managed PATH prepend/append snippets and the LLVM bin directory.
  # The `-replace` substitutions are safe: the replacement snippets contain no
  # `$1`-style regex group references (.NET leaves unknown `$name` sequences
  # literal), and the prepend/append lines are embedded via `$managedBlockStart`
  # marker on both sides.
  $managedBlock = @($managedBlockStart) + (((Get-Content -Raw (Join-Path $PSScriptRoot -ChildPath '..\..\..\..\scripts\shell\profile.ps1')) -replace '__NUCLEUS_PREPEND_PATH__', ($prependLines -join "`r`n") -replace '__NUCLEUS_APPEND_PATH__', ($appendLines -join "`r`n") -replace '__NUCLEUS_LLVM_BIN_DIR__', (Get-NucleusLLVMBinDir)) -split '\r?\n') + @($managedBlockEnd)

  $profilePaths = @(
    $PROFILE.CurrentUserCurrentHost,
    $PROFILE.CurrentUserAllHosts
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($profilePath in $profilePaths) {
    $profileDirectory = Split-Path -Path $profilePath -Parent
    if ($Enabled -and -not (Test-Path -Path $profileDirectory)) {
      New-Item -ItemType Directory -Path $profileDirectory -Force > $null
    }

    $existingLines = @()
    if (Test-Path -Path $profilePath) {
      $existingLines = @(Get-Content -Path $profilePath)
    }

    $filteredLines = @()
    $insideManagedBlock = $false
    foreach ($line in $existingLines) {
      if ($line -eq $managedBlockStart) {
        $insideManagedBlock = $true
        continue
      }

      if ($line -eq $managedBlockEnd) {
        $insideManagedBlock = $false
        continue
      }

      if (-not $insideManagedBlock) {
        $filteredLines += $line
      }
    }

    if ($Enabled) {
      if ($filteredLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($filteredLines[-1])) {
        $filteredLines += ''
      }

      $filteredLines += $managedBlock
    }

    $hasNonWhitespaceLines = ($filteredLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasNonWhitespaceLines) {
      [System.IO.File]::WriteAllLines($profilePath, $filteredLines, [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path -Path $profilePath) {
      Remove-Item -Path $profilePath -Force
    }
  }
}
