# modules/windows/shell.ps1 — Shell parity helpers for Windows.
#
# Maintains a managed block in PowerShell profile files for cross-host shell
# behavior parity (direnv hook and helper aliases).

function Sync-ShellProfile {
  <#
  .SYNOPSIS
    Converges a managed shell-parity block in PowerShell profile files.

  .DESCRIPTION
    Writes or removes a bounded managed block in:
      - CurrentUserCurrentHost profile
      - CurrentUserAllHosts profile

    Managed content intentionally mirrors key POSIX shell workflow behavior:
      - direnv integration (if direnv is present)
      - PSReadLine predictive history completion and menu-style tab expansion
        (if PSReadLine module is available; bundled with pwsh on all supported hosts)
      - zoxide smart directory navigation (if zoxide is present)
      - fzf Ctrl+R fuzzy history search via PSReadLine key handler
        (if fzf is present and PSReadLine is available)
      - pay-respects command correction hook (if pay-respects is present; installed
        via cargo-binstall by Invoke-CargoBinstallSetup)
      - common aliases (`g`, `ga`, `gc`, `gca`, `gco`, `gd`, `gll`, `gp`,
        `gpl`, `gs-pdf-opt-*` (Ghostscript PDF presets), `gst`, `la`, `ll` (eza preferred, Get-ChildItem fallback),
        `ni`, `nr`, `nx` (bun shortcuts, if bun present), `v`)
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
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $managedBlockStart = '# >>> config managed shell parity >>>'
  $managedBlockEnd = '# <<< config managed shell parity <<<'
  $managedBlock = @(
    $managedBlockStart
    'if (Get-Command direnv -ErrorAction SilentlyContinue) {'
    '  (& direnv hook pwsh) | Out-String | Invoke-Expression'
    '}'
    '# Keep the managed default dev environment active outside project-specific'
    '# direnv contexts. Windows does not have a separate nix-direnv-backed store'
    '# path here, so the fallback reuses the managed user PATH entries applied by'
    '# WinGet/bootstrap while still gating invocation through this profile layer.'
    '$env:NUCLEUS_DEFAULT_DEV_ENV = "1"'
    # Load rclone config passphrase from materialized secret for automatic config
    # file encryption in interactive and scripted rclone invocations.
    # WHY conditional: secret file may be absent before apply has materialized it.
    '$_rclonePassFile = Join-Path $HOME ".config\nucleus\secrets\rclone-config-pass"'
    'if (Test-Path -Path $_rclonePassFile -PathType Leaf) {'
    '  $env:RCLONE_CONFIG_PASS = (Get-Content -Path $_rclonePassFile -Raw -ErrorAction SilentlyContinue).Trim()'
    '  Remove-Variable -Name _rclonePassFile -ErrorAction SilentlyContinue'
    '}'
    # PSReadLine: predictive history completion + menu-style tab expansion.
    # Guards with module availability probe so the profile is safe on older hosts.
    'if (Get-Module -ListAvailable -Name PSReadLine) {'
    '  Import-Module PSReadLine'
    '  Set-PSReadLineOption -PredictionSource History'
    '  Set-PSReadLineOption -PredictionViewStyle ListView'
    '  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete'
    '}'
    # zoxide: smart directory navigation learned from visit history.
    'if (Get-Command zoxide -ErrorAction SilentlyContinue) {'
    '  Invoke-Expression (& zoxide init powershell | Out-String)'
    '}'
    # fzf: fuzzy history search on Ctrl+R via a PSReadLine key handler.
    # Reads the PSReadLine history file directly so all sessions are searchable.
    'if ((Get-Command fzf -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name PSReadLine)) {'
    '  Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock {'
    '    $line = $null'
    '    $cursor = $null'
    '    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)'
    '    $histFile = (Get-PSReadLineOption).HistorySavePath'
    '    $selected = Get-Content -Path $histFile -ErrorAction SilentlyContinue |'
    '      Where-Object { $_ } | Sort-Object -Unique |'
    '      & fzf --tac --no-sort --height 40% --query $line'
    '    if ($LASTEXITCODE -eq 0 -and $selected) {'
    '      [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()'
    '      [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)'
    '    }'
    '  }'
    '}'
    # pay-respects: register correction hook when the binary is present.
    # -ErrorAction SilentlyContinue is intentional: pay-respects may be absent
    # on first-provision before cargo-binstall setup has run; the if-guard
    # checks the result immediately so no failure is silently swallowed.
    # In PowerShell, functions take higher precedence than aliases in command
    # lookup, so the `f` function defined by pay-respects --alias is not
    # shadowed by any alias of the same name (unlike zsh where aliases shadow
    # functions).
    'if (Get-Command pay-respects -ErrorAction SilentlyContinue) {'
    '  iex (& pay-respects pwsh --alias | Out-String)'
    '}'
    # prek: install repository-local Git hooks automatically the first time a
    # shell session enters a repo that opted into prek via prek.toml.
    # The hook first checks for the canonical generated shims so already-
    # provisioned repos stay quiet across new shell sessions, then falls back
    # to a per-session cache to avoid repeated installs after the first run.
    '$global:__nucleusPrekCheckedRepos = @{}'
    '$global:__nucleusPrekInstallInProgress = $false'
    'function Test-PrekHooksInstalled {'
    '  param('
    '    [Parameter(Mandatory = $true)]'
    '    [string]$RepositoryRoot'
    '  )'
    '  $hookDir = Join-Path $RepositoryRoot ".git/hooks"'
    '  if (-not (Test-Path -Path $hookDir -PathType Container)) {'
    '    return $false'
    '  }'
    '  foreach ($hookPath in Get-ChildItem -Path $hookDir -File) {'
    '    if (Select-String -Path $hookPath.FullName -Pattern ''# File generated by prek'' -SimpleMatch -Quiet) {'
    '      return $true'
    '    }'
    '  }'
    '  return $false'
    '}'
    'function Invoke-PrekHookInstallIfNeeded {'
    '  # Get-Command is a presence probe here; absence is expected on unmanaged'
    '  # shells, and the function returns immediately after the check.'
    '  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {'
    '    return'
    '  }'
    '  if (-not (Get-Command prek -ErrorAction SilentlyContinue)) {'
    '    return'
    '  }'
    '  # git rev-parse is a repo-membership probe here; suppress the expected'
    '  # stderr from non-repository directories and branch on the result.'
    '  $repoRootOutput = & git -C (Get-Location).Path rev-parse --show-toplevel 2>$null'
    '  if ($null -eq $repoRootOutput) {'
    '    return'
    '  }'
    '  $repoRoot = ($repoRootOutput | Out-String).Trim()'
    '  if ([string]::IsNullOrWhiteSpace($repoRoot)) {'
    '    return'
    '  }'
    '  $prekConfigPath = Join-Path $repoRoot "prek.toml"'
    '  if (-not (Test-Path -Path $prekConfigPath -PathType Leaf)) {'
    '    return'
    '  }'
    '  if ($global:__nucleusPrekInstallInProgress) {'
    '    return'
    '  }'
    '  if ($global:__nucleusPrekCheckedRepos.ContainsKey($repoRoot)) {'
    '    return'
    '  }'
    '  if (Test-PrekHooksInstalled -RepositoryRoot $repoRoot) {'
    '    $global:__nucleusPrekCheckedRepos[$repoRoot] = $true'
    '    return'
    '  }'
    '  $global:__nucleusPrekInstallInProgress = $true'
    '  Write-Host "prek: installing hooks in $repoRoot" -ForegroundColor Cyan'
    '  Push-Location $repoRoot'
    '  try {'
    '    & prek install'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "prek install failed with exit code $LASTEXITCODE"'
    '    }'
    '    $global:__nucleusPrekCheckedRepos[$repoRoot] = $true'
    '  } catch {'
    '    Write-Warning "prek: failed to install hooks in $repoRoot — $($_.Exception.Message)"'
    '  } finally {'
    '    $global:__nucleusPrekInstallInProgress = $false'
    '    Pop-Location'
    '  }'
    '}'
    'if (-not $global:__nucleusPrekPromptWrapped) {'
    '  $global:__nucleusPrekPromptWrapped = $true'
    '  $global:__nucleusPrekPreviousPrompt = if (Test-Path Function:\prompt) {'
    '    (Get-Command prompt -CommandType Function).ScriptBlock'
    '  } else {'
    '    $null'
    '  }'
    '  function global:prompt {'
    '    Invoke-PrekHookInstallIfNeeded'
    '    if ($null -ne $global:__nucleusPrekPreviousPrompt) {'
    '      & $global:__nucleusPrekPreviousPrompt'
    '    } else {'
    '      "PS $(Get-Location)> "'
    '    }'
    '  }'
    '}'
    'Invoke-PrekHookInstallIfNeeded'
    # bun global packages land in ~\.bun\bin (BUN_INSTALL_BIN default).
    # WinGet bun installer adds this to the user PATH registry entry; the
    # prepend here covers sessions opened before that registry change was
    # applied (for example the terminal running apply.ps1 itself).
    '$bunBinDir = Join-Path $env:USERPROFILE ".bun\bin"'
    'if ((Test-Path $bunBinDir) -and ($env:PATH -notlike "*$bunBinDir*")) {'
    '  $env:PATH = "$bunBinDir;$env:PATH"'
    '}'
    # LLVM/Clang: add LLVM bin directory to PATH for the current session so
    # newly provisioned hosts can run clang/ld.lld immediately.
    '$llvmBinDir = "C:\Program Files\LLVM\bin"'
    'if ((Test-Path $llvmBinDir) -and ($env:PATH -notlike "*$llvmBinDir*")) {'
    '  $env:PATH = "$llvmBinDir;$env:PATH"'
    '}'
    '$env:CC = "clang"'
    '$env:CXX = "clang++"'
    '$env:LD = "ld.lld"'
    'function g { & git @Args }'
    'function ga { & git add @Args }'
    'function gc { & git commit @Args }'
    'function gca { & git commit --amend @Args }'
    'function gco { & git checkout @Args }'
    'function gd { & git diff @Args }'
    'function gll { & git log --oneline --decorate --graph @Args }'
    'function gp { & git push @Args }'
    'function gpl { & git pull @Args }'
    'function Invoke-NucleusGhostscript {'
    '  if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }'
    '  if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }'
    '  if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }'
    '  throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"'
    '}'
    # Ghostscript PDF optimization presets.
    # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
    # newer PDF compatibility target is released by Ghostscript.
    'function gs-pdf-opt-default  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default  -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function gs-pdf-opt-ebook    { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook    -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function gs-pdf-opt-prepress { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function gs-pdf-opt-printer  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer  -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function gs-pdf-opt-screen   { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen   -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function gst { & git status @Args }'
    # la/ll: prefer eza for colour, icons, and extended metadata; fall back to
    # Get-ChildItem when eza is absent so the profile loads on unmanaged machines.
    'if (Get-Command eza -ErrorAction SilentlyContinue) {'
    '  function la { & eza -la @Args }'
    '  function ll { & eza -la @Args }'
    '} else {'
    '  function la { Get-ChildItem -Force @Args }'
    '  function ll { Get-ChildItem -Force @Args }'
    '}'
    # bun shortcuts: mirrors ni/nr/nx aliases in shell/aliases.nix on POSIX hosts.
    # Guarded so the profile loads safely on machines where bun is not yet installed.
    'if (Get-Command bun -ErrorAction SilentlyContinue) {'
    '  function ni { & bun install @Args }'
    '  function nr { & bun run @Args }'
    '  function nx { & bun x @Args }'
    '}'
    'function Resolve-NucleusRepoRoot {'
    '  $configPath = Join-Path $HOME ''.config\nucleus\repo-root'''
    '  if (Test-Path -Path $configPath -PathType Leaf) {'
    '    $configuredRoot = (Get-Content -Path $configPath -Raw).Trim()'
    '    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and (Test-Path -Path $configuredRoot -PathType Container)) {'
    '      return $configuredRoot'
    '    }'
    '  }'
    '  # git rev-parse stderr is suppressed because non-repo CWD is expected'
    '  # and benign here; the result is validated before use.'
    '  $gitRoot = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String).Trim()'
    '  if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -Path $gitRoot -PathType Container)) {'
    '    return $gitRoot'
    '  }'
    '  return (Join-Path $HOME ''dev\nucleus'')'
    '}'
    'function nucleus-cloud-setup {'
    '  $repoRoot = Resolve-NucleusRepoRoot'
    '  $scriptPath = Join-Path $repoRoot ''scripts\cloud-setup.ps1'''
    '  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {'
    '    throw "nucleus-cloud-setup: script not found at $scriptPath"'
    '  }'
    '  & $scriptPath @Args'
    '}'
    'function nucleus-replica-bisync {'
    '  $repoRoot = Resolve-NucleusRepoRoot'
    '  $scriptPath = Join-Path $repoRoot ''scripts\replica-bisync.ps1'''
    '  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {'
    '    throw "nucleus-replica-bisync: script not found at $scriptPath"'
    '  }'
    '  & $scriptPath @Args'
    '}'
    'function nucleus-replica-reset {'
    '  $repoRoot = Resolve-NucleusRepoRoot'
    '  $scriptPath = Join-Path $repoRoot ''scripts\replica-reset.ps1'''
    '  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {'
    '    throw "nucleus-replica-reset: script not found at $scriptPath"'
    '  }'
    '  & $scriptPath @Args'
    '}'
    'function v { & nvim @Args }'
    'function Test-NucleusPythonScopeActive {'
    '  return (-not [string]::IsNullOrWhiteSpace($env:VIRTUAL_ENV)) -or (-not [string]::IsNullOrWhiteSpace($env:CONDA_PREFIX))'
    '}'
    'function Invoke-NucleusPythonScopedTool {'
    '  param('
    '    [Parameter(Mandatory = $true)]'
    '    [string]$ToolName,'
    '    [Parameter(ValueFromRemainingArguments = $true)]'
    '    [object[]]$ToolArguments'
    '  )'
    '  if (-not (Test-NucleusPythonScopeActive)) {'
    '    return $false'
    '  }'
    '  $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1'
    '  if ($null -eq $application) {'
    '    return $false'
    '  }'
    '  & $application.Source @ToolArguments'
    '  return $true'
    '}'
    '# System-wide Python ban: redirect python/pip to warnings'
    'function python {'
    '  if (Invoke-NucleusPythonScopedTool -ToolName "python" @Args) {'
    '    return'
    '  }'
    '  Write-Host "python-ban: system-wide Python is banned to prevent accidental modifications." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow >&2'
    '  Write-Host "         - nix develop     (activate project devShell with scoped Python)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - uv run <cmd>    (run Python via uv package manager)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - .\venv\Scripts\python (use pre-existing project venv)" -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    'function python3 {'
    '  if (Invoke-NucleusPythonScopedTool -ToolName "python3" @Args) {'
    '    return'
    '  }'
    '  python @Args'
    '}'
    'function pip {'
    '  if (Invoke-NucleusPythonScopedTool -ToolName "pip" @Args) {'
    '    return'
    '  }'
    '  Write-Host "python-ban: system-wide pip is banned to prevent breaking system dependencies." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow >&2'
    '  Write-Host "         - nix develop     (activate project devShell with scoped Python+pip)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - uv pip install  (use uv to manage project dependencies)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - .\venv\Scripts\pip (use pre-existing project venv)" -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    'function pip3 {'
    '  if (Invoke-NucleusPythonScopedTool -ToolName "pip3" @Args) {'
    '    return'
    '  }'
    '  pip @Args'
    '}'
    '# Route managed development tools through either an active direnv context'
    '# or the managed default shell environment for repositories without .envrc.'
    'function Invoke-NucleusManagedDevTool {'
    '  param('
    '    [Parameter(Mandatory = $true)]'
    '    [string]$ToolName,'
    '    [Parameter(ValueFromRemainingArguments = $true)]'
    '    [object[]]$ToolArguments'
    '  )'
    '  $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1'
    '  if ($null -eq $application) {'
    '    return $false'
    '  }'
    '  if ($env:DIRENV_DIR -or $env:NUCLEUS_DEFAULT_DEV_ENV) {'
    '    & $application.Source @ToolArguments'
    '    return $true'
    '  }'
    '  return $false'
    '}'
    # System-wide build tool block: redirect bun/cargo/rustc/uv to warnings.
    # These tools are installed globally for system package management only.
    # When DIRENV_DIR is set, a direnv environment (devShell) is active; when it
    # is absent, use the managed default shell environment so plain repos still
    # have a safe baseline toolchain. WHY: Windows does not have a separate
    # nix-direnv-backed fallback store path in this workflow yet, so parity uses
    # the user-scoped managed PATH instead of a second binary install root.
    'function bun {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "bun" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed bun is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or use the managed default shell environment installed by apply.ps1" -ForegroundColor Yellow'
    '  Write-Host "         Shell shortcuts ni/nr/nx also work inside a devShell." -ForegroundColor Yellow'
    '  return 1'
    '}'
    'function cargo {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "cargo" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed cargo is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or use the managed default shell environment installed by apply.ps1" -ForegroundColor Yellow'
    '  return 1'
    '}'
    'function rustc {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "rustc" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed rustc is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or use the managed default shell environment installed by apply.ps1" -ForegroundColor Yellow'
    '  return 1'
    '}'
    'function uv {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "uv" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed uv is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For Python development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or use the managed default shell environment installed by apply.ps1" -ForegroundColor Yellow'
    '  return 1'
    '}'
    $managedBlockEnd
  )

  $profilePaths = @(
    $PROFILE.CurrentUserCurrentHost,
    $PROFILE.CurrentUserAllHosts
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($profilePath in $profilePaths) {
    $profileDirectory = Split-Path -Path $profilePath -Parent
    if ($Enabled -and -not (Test-Path -Path $profileDirectory)) {
      New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
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
