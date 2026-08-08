# This file is managed by nucleus (src/scripts/shell/profile.ps1).
# Manual edits will be overwritten on the next apply.
#
# Shared PowerShell profile content, deployed to both platforms:
# - POSIX (macOS, NixOS): embedded by src/modules/pwsh.nix after init.ps1 via
#   builtins.readFile.  The __NUCLEUS_*__ tokens are replaced with empty strings,
#   leaving the `if ($IsWindows)` blocks inert.
# - Windows: read by src/platforms/Windows/modules/user/Sync-ShellProfile.ps1, which
#   substitutes __NUCLEUS_PREPEND_PATH__/__NUCLEUS_APPEND_PATH__ with the managed
#   PATH snippets and __NUCLEUS_LLVM_BIN_DIR__ with the LLVM bin directory, then
#   writes the result into the user's PowerShell profile managed block.

# Managed PATH: prepend/append dirs, substituted by the embedding host
# (Sync-ShellProfile.ps1 on Windows; empty on POSIX).
__NUCLEUS_PREPEND_PATH__
__NUCLEUS_APPEND_PATH__

if ($IsWindows) {
  # Load rclone config passphrase from materialized secret for automatic config
  # file encryption in interactive and scripted rclone invocations.
  # WHY: conditional: secret file may be absent before apply has materialized it.
  $_rclonePassFile = Join-Path $HOME ".config\nucleus\secrets\rclone-config-pass"
  if (Test-Path -Path $_rclonePassFile -PathType Leaf) {
    # check-suppress:suppression_doc: file may not exist yet (first provision); absence is expected and handled downstream.
    $env:RCLONE_CONFIG_PASS = (Get-Content -Path $_rclonePassFile -Raw -ErrorAction SilentlyContinue).Trim()
    # check-suppress:suppression_doc: resource may already be released; idempotent cleanup, not error swallowing.
    Remove-Variable -Name _rclonePassFile -ErrorAction SilentlyContinue
  }
  # LLVM/Clang: add LLVM bin directory to PATH for the current session so
  # newly provisioned hosts can run clang/ld.lld immediately.
  # CC/CXX/LD are set at Machine scope via system/env.dsc.yml for
  # all-process visibility.  Source: src/modules/lib/env-catalog.nix.
  $llvmBinDir = "__NUCLEUS_LLVM_BIN_DIR__"
  if ((Test-Path $llvmBinDir) -and ($env:PATH -notlike "*$llvmBinDir*")) {
    $env:PATH = "$env:PATH;$llvmBinDir"
  }
  # AI agent session detection: suppress pay-respects when VSCODE_AGENT,
  # CLAUDECODE, etc. are set.
  # Source of truth for env var names: src/modules/agent-env-vars.nix.
  # Windows variant; POSIX hosts get Test-NucleusAgentSession from init.ps1
  # (token-based, /opt/.devin marker only).
  function Test-NucleusAgentSession {
    # Standard AI agent environment variables
    if (Test-Path env:AGENT) { return $true }
    if (Test-Path env:AI_AGENT) { return $true }
    # Tool-specific environment variables
    if (Test-Path env:VSCODE_AGENT) { return $true }
    if (Test-Path env:CLAUDECODE) { return $true }
    if (Test-Path env:CLAUDE_CODE) { return $true }
    if (Test-Path env:CURSOR_AGENT) { return $true }
    if (Test-Path env:GOOSE_TERMINAL) { return $true }
    if (Test-Path env:CLINE_ACTIVE) { return $true }
    if (Test-Path env:GEMINI_CLI) { return $true }
    if (Test-Path env:CODEX_SANDBOX) { return $true }
    if (Test-Path env:TRAE_AI_SHELL_ID) { return $true }
    if (Test-Path env:AUGMENT_AGENT) { return $true }
    if (Test-Path env:NUCLEUS_AGENT_SESSION) { return $true }
    if (Test-Path env:OPENCODE_CLIENT) { return $true }
    # Devin filesystem marker
    if (Test-Path "/opt/.devin") { return $true }
    if (Test-Path "C:\opt\.devin") { return $true }
    return $false
  }
}

# direnv: load per-directory environments defined in .envrc files.
# check-suppress:suppression_doc: tool-availability guard -- direnv may not be installed
if (Get-Command direnv -ErrorAction SilentlyContinue) {
  . ([ScriptBlock]::Create((& direnv hook pwsh | Out-String)))
}

# PSReadLine: predictive history completion and menu-style tab expansion.
# Guards with module availability probe so the profile loads on hosts where
# PSReadLine is absent or an unexpected version is installed.
if (Get-Module -ListAvailable -Name PSReadLine) {
  Import-Module PSReadLine
  Set-PSReadLineOption -PredictionSource History
  Set-PSReadLineOption -PredictionViewStyle ListView
  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
  Set-PSReadLineOption -HistoryNoDuplicates
  Set-PSReadLineOption -AddToHistoryHandler {
    param($line)
    $line -notmatch '^\s'
  }
}

# zoxide: smart directory navigation learned from visit history.
# check-suppress:suppression_doc: tool-availability guard -- zoxide may not be installed
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
  . ([ScriptBlock]::Create((& zoxide init powershell | Out-String)))
}

# Starship prompt: cross-shell prompt with git/nix/status info.
# check-suppress:suppression_doc: tool-availability guard -- starship may not be installed
if (Get-Command starship -ErrorAction SilentlyContinue) {
  . ([ScriptBlock]::Create((& starship init powershell | Out-String)))
}

# ---------------------------------------------------------------
# Interactive-feature suppression in AI agent sessions
# ---------------------------------------------------------------
# When an AI agent is detected, disable PSReadLine and other interactive
# features that serve no purpose and clutter output in non-human sessions.
if (Test-NucleusAgentSession) {
  # check-suppress:suppression_doc: module may not be loaded in non-interactive sessions
  Remove-Module PSReadLine -ErrorAction SilentlyContinue
  $ConfirmPreference = 'None'
  function prompt { "PS> " }
}

# ---------------------------------------------------------------
# pay-respects shell hook
# ---------------------------------------------------------------
# Only initialise in interactive, non-agent, and available sessions.
# In non-interactive or AI agent sessions, pay-respects would block on
# its interactive prompt with no user to respond.
# check-suppress:suppression_doc: tool-availability guard -- pay-respects may not be installed
if ([Environment]::UserInteractive -and -not (Test-NucleusAgentSession) -and (Get-Command pay-respects -ErrorAction SilentlyContinue)) {
  . ([ScriptBlock]::Create((& pay-respects pwsh --alias | Out-String)))
}

# prek: install repository-local Git hooks automatically the first time a
# shell session enters a repo that opted into prek via prek.toml.
# The hook first checks for the canonical generated shims so already-
# provisioned repos stay quiet across new shell sessions, then falls back
# to a per-session cache to avoid repeated installs after the first run.
$script:__nucleusPrekCheckedRepos = @{}
$script:__nucleusPrekInstallInProgress = $false
function Test-PrekHooksInstalled {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
  )

  # WHY: git rev-parse: handles .git as file (submodules, worktrees) + directory.
  # Avoids silent failure when .git is a gitlink (file with gitdir: path).
  # check-suppress:suppression_doc: may run outside a git repo; 2>$null is the explicit guard
  $gitDirOutput = & git -C $RepositoryRoot rev-parse --git-dir 2>$null
  if (-not $gitDirOutput) {
    return $false
  }

  # Handle relative and absolute paths from git rev-parse --git-dir
  $gitDir = ($gitDirOutput | Out-String).Trim()
  if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
    $gitDir = Join-Path -Path $RepositoryRoot -ChildPath $gitDir
  }

  $hookDir = Join-Path -Path $gitDir -ChildPath "hooks"
  if (-not (Test-Path -Path $hookDir -PathType Container)) {
    return $false
  }

  foreach ($hookPath in Get-ChildItem -Path $hookDir -File) {
    if (Select-String -Path $hookPath.FullName -Pattern '# File generated by prek' -SimpleMatch -Quiet) {
      return $true
    }
  }

  return $false
}
function Invoke-PrekHookInstallIfNeeded {
  # Get-Command is a presence probe here; absence is expected on unmanaged
  # shells, and the function returns immediately after the check.
  # check-suppress:suppression_doc: tool-availability guard -- git may not be installed
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    return
  }
  # check-suppress:suppression_doc: tool-availability guard -- prek may not be installed
  if (-not (Get-Command prek -ErrorAction SilentlyContinue)) {
    return
  }

  # git rev-parse is a repo-membership probe here; suppress the expected
  # stderr from non-repository directories and branch on the result.
  # check-suppress:suppression_doc: repo-membership probe -- expected stderr outside a git repo
  $repoRootOutput = & git -C (Get-Location).Path rev-parse --show-toplevel 2>$null
  if ($null -eq $repoRootOutput) {
    return
  }
  $repoRoot = ($repoRootOutput | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    return
  }

  $prekConfigPath = Join-Path $repoRoot "prek.toml"
  if (-not (Test-Path -Path $prekConfigPath -PathType Leaf)) {
    return
  }
  if ($script:__nucleusPrekInstallInProgress) {
    return
  }
  if ($script:__nucleusPrekCheckedRepos.ContainsKey($repoRoot)) {
    return
  }
  if (Test-PrekHooksInstalled -RepositoryRoot $repoRoot) {
    $script:__nucleusPrekCheckedRepos[$repoRoot] = $true
    return
  }

  $script:__nucleusPrekInstallInProgress = $true
  Write-Output "prek: installing hooks in $repoRoot"
  Push-Location $repoRoot
  try {
    & prek install
    if ($LASTEXITCODE -ne 0) {
      throw "prek install failed with exit code $LASTEXITCODE"
    }

    $script:__nucleusPrekCheckedRepos[$repoRoot] = $true
  }
  catch {
    Write-Warning "prek: failed to install hooks in $repoRoot — $($_.Exception.Message)"
  }
  finally {
    $script:__nucleusPrekInstallInProgress = $false
    Pop-Location
  }
}

if (-not $script:__nucleusPrekPromptWrapped) {
  $script:__nucleusPrekPromptWrapped = $true
  $script:__nucleusPrekPreviousPrompt = if (Test-Path Function:\prompt) {
    (Get-Command prompt -CommandType Function).ScriptBlock
  } else {
    $null
  }

  function global:prompt {
    Invoke-PrekHookInstallIfNeeded
    if ($null -ne $script:__nucleusPrekPreviousPrompt) {
      & $script:__nucleusPrekPreviousPrompt
    } else {
      "PS $(Get-Location)> "
    }
  }
}

Invoke-PrekHookInstallIfNeeded

# fzf: fuzzy history search on Ctrl+R via a PSReadLine key handler.
# Reads the PSReadLine history file directly so all sessions are searchable.
# Guard requires both fzf and PSReadLine to avoid silently failing on a
# host where fzf is installed but the module is missing.
# check-suppress:suppression_doc: tool-availability guard -- fzf may not be installed
if ((Get-Command fzf -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name PSReadLine)) {
  Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $histFile = (Get-PSReadLineOption).HistorySavePath
    # check-suppress:suppression_doc: history file may not exist if PSReadLine was never used
    $selected = Get-Content -Path $histFile -ErrorAction SilentlyContinue |
      Where-Object { $_ } | Sort-Object -Unique |
      & fzf --tac --no-sort --height 40% --query $line
    if ($LASTEXITCODE -eq 0 -and $selected) {
      [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
      [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)
    }
  }
}

# Git shell aliases — mirrors src/modules/shell/aliases.nix
# Use Add-ShellAlias (not `function` or inline `New-Item -Path Function:`) for all shell aliases.
# The helper wraps the PSFunction provider path, which bypasses PSUseApprovedVerbs by avoiding
# a FunctionDefinitionAst — the one and only AST node type that rule inspects.
# Naming conventions:
# - Prefix = base git command (all `git log` aliases start with `-gl`).
# - `-gca*` = amend (every alias starting with `-gca` expands to `git commit --amend ...`).
# - No casing distinction (case-insensitive on Windows).
# - Double letter = more: more verbose, more forceful, or full form.
# - All options MUST use long form (--patch, --all, --message, etc.). See aliases.nix header.
function Add-ShellAlias {
  param([string]$Name, [scriptblock]$Value)
  # check-suppress:suppression_doc: New-Item returns FileInfo, discarded
  $null = New-Item -Path Function: -Name $Name -Value $Value -Force
}
Add-ShellAlias '-g' { & git @Args }
Add-ShellAlias '-ga' { & git add @Args }
Add-ShellAlias '-gap' { & git add --patch @Args }
Add-ShellAlias '-gb' { & git branch @Args }
Add-ShellAlias '-gba' { & git branch --all @Args }
Add-ShellAlias '-gbd' { & git branch --delete @Args }
Add-ShellAlias '-gbdd' { & git branch --delete --force @Args }
Add-ShellAlias '-gbm' { & git branch --move @Args }
Add-ShellAlias '-gc' { & git commit @Args }
Add-ShellAlias '-gca' { & git commit --amend @Args }
Add-ShellAlias '-gcaa' { & git commit --all --amend @Args }
Add-ShellAlias '-gcam' { & git commit --amend --message @Args }
Add-ShellAlias '-gcl' { & git clone @Args }
# git clean matrix: prefix = force level, suffix = ignore scope (see aliases.nix).
Add-ShellAlias '-gclean' { & git clean --dry-run -d @Args }
Add-ShellAlias '-gcleanf' { & git clean --force -d @Args }
Add-ShellAlias '-gcleanff' { & git clean --force --force -d @Args }
Add-ShellAlias '-gcleanffx' { & git clean --force --force -d -x @Args }
Add-ShellAlias '-gcleanffxx' { & git clean --force --force -d -X @Args }
Add-ShellAlias '-gcleanfx' { & git clean --force -d -x @Args }
Add-ShellAlias '-gcleanfxx' { & git clean --force -d -X @Args }
Add-ShellAlias '-gcleanx' { & git clean --dry-run -d -x @Args }
Add-ShellAlias '-gcleanxx' { & git clean --dry-run -d -X @Args }
Add-ShellAlias '-gcm' { & git commit --message @Args }
Add-ShellAlias '-gcma' { & git commit --all --message @Args }
Add-ShellAlias '-gco' { & git checkout @Args }
Add-ShellAlias '-gcob' { & git checkout --branch @Args }
Add-ShellAlias '-gd' { & git diff @Args }
Add-ShellAlias '-gdc' { & git diff --cached @Args }
Add-ShellAlias '-gds' { & git diff --stat @Args }
Add-ShellAlias '-gf' { & git fetch @Args }
Add-ShellAlias '-gfa' { & git fetch --all @Args }
Add-ShellAlias '-gff' { & git fetch --force @Args }
Add-ShellAlias '-gg' { & git grep @Args }
Add-ShellAlias '-gl' { & git log --oneline --decorate --graph @Args }
Add-ShellAlias '-gla' { & git log --oneline --decorate --graph --all @Args }
Add-ShellAlias '-gll' { & git log --decorate --graph --show-signature --stat @Args }
Add-ShellAlias '-glla' { & git log --decorate --graph --show-signature --stat --all @Args }
Add-ShellAlias '-glp' { & git log --oneline --decorate --graph --patch @Args }
Add-ShellAlias '-gls' { & git log --oneline --decorate --graph --stat @Args }
Add-ShellAlias '-gm' { & git merge @Args }
Add-ShellAlias '-gma' { & git merge --abort @Args }
Add-ShellAlias '-gmnff' { & git merge --no-ff @Args }
Add-ShellAlias '-gp' { & git push @Args }
Add-ShellAlias '-gpf' { & git push --force-with-lease @Args }
Add-ShellAlias '-gpff' { & git push --force @Args }
Add-ShellAlias '-gpl' { & git pull @Args }
Add-ShellAlias '-gplf' { & git pull --force @Args }
Add-ShellAlias '-gplo' { & git pull origin @Args }
Add-ShellAlias '-gplr' { & git pull --rebase @Args }
Add-ShellAlias '-gpo' { & git push origin @Args }
Add-ShellAlias '-gr' { & git remote @Args }
Add-ShellAlias '-grb' { & git rebase @Args }
Add-ShellAlias '-grba' { & git rebase --abort @Args }
Add-ShellAlias '-grbc' { & git rebase --continue @Args }
Add-ShellAlias '-grbi' { & git rebase --interactive @Args }
Add-ShellAlias '-grbm' { & git rebase main @Args }
Add-ShellAlias '-grbo' { & git rebase --onto @Args }
Add-ShellAlias '-grbs' { & git rebase --skip @Args }
Add-ShellAlias '-grev' { & git revert @Args }
Add-ShellAlias '-grs' { & git reset @Args }
Add-ShellAlias '-grsh' { & git reset --soft HEAD~ @Args }
Add-ShellAlias '-grshh' { & git reset --hard HEAD~ @Args }
Add-ShellAlias '-grv' { & git remote --verbose @Args }
# git status in short format with branch info, restored from git history.
Add-ShellAlias '-gs' { & git status --short --branch @Args }
Add-ShellAlias '-gsh' { & git show @Args }
Add-ShellAlias '-gss' { & git status @Args }
# WHY: bare `git stash` (not `push`): no-arg still pushes (default subcommand),
# and any stash subcommand works via args (e.g. `-gst list`).
Add-ShellAlias '-gst' { & git stash @Args }
Add-ShellAlias '-gstd' { & git stash drop @Args }
Add-ShellAlias '-gstl' { & git stash list @Args }
Add-ShellAlias '-gstp' { & git stash pop @Args }
Add-ShellAlias '-gstsh' { & git stash show --patch @Args }
Add-ShellAlias '-gsw' { & git switch @Args }
Add-ShellAlias '-gswc' { & git switch --create @Args }
Add-ShellAlias '-gt' { & git tag @Args }
Add-ShellAlias '-gtd' { & git tag --delete @Args }
Add-ShellAlias '-gtl' { & git tag --list @Args }

# --- Ghostscript PDF optimization aliases ---
function Invoke-NucleusGhostscript {
  # check-suppress:suppression_doc: tool-availability guard -- Ghostscript CLI may not be installed
  if (Get-Command gs -ErrorAction SilentlyContinue) {
    & gs @Args
    return
  }
  # check-suppress:suppression_doc: tool-availability guard -- Ghostscript CLI may not be installed
  if (Get-Command gswin64c -ErrorAction SilentlyContinue) {
    & gswin64c @Args
    return
  }
  # check-suppress:suppression_doc: tool-availability guard -- Ghostscript CLI may not be installed
  if (Get-Command gswin32c -ErrorAction SilentlyContinue) {
    & gswin32c @Args
    return
  }
  throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
}

# CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
# newer PDF compatibility target is released by Ghostscript.
Add-ShellAlias '-gs-pdf-opt-default' { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default  -dNOPAUSE -dQUIET -dBATCH @Args }
Add-ShellAlias '-gs-pdf-opt-prepress' { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH @Args }
Add-ShellAlias '-gs-pdf-opt-printer' { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer  -dNOPAUSE -dQUIET -dBATCH @Args }
Add-ShellAlias '-gs-pdf-opt-ebook' { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook    -dNOPAUSE -dQUIET -dBATCH @Args }
Add-ShellAlias '-gs-pdf-opt-screen' { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen   -dNOPAUSE -dQUIET -dBATCH @Args }

# la/ll: prefer eza for colour, icons, and extended metadata; fall back to
# Get-ChildItem when eza is absent so the profile loads on unmanaged machines.
# check-suppress:suppression_doc: tool-availability guard -- eza may not be installed
if (Get-Command eza -ErrorAction SilentlyContinue) {
  Add-ShellAlias '-la' { & eza --long --all @Args }
  Add-ShellAlias '-ll' { & eza --long --all @Args }
} else {
  Add-ShellAlias '-la' { Get-ChildItem -Force @Args }
  Add-ShellAlias '-ll' { Get-ChildItem -Force @Args }
}

# bun shortcuts: mirrors the full -n* alias set in shell/aliases.nix on POSIX hosts.
# Guarded so the profile loads safely on machines where bun is not yet installed.
# check-suppress:suppression_doc: tool-availability guard -- bun may not be installed
if (Get-Command bun -ErrorAction SilentlyContinue) {
  Add-ShellAlias '-n' { & bun @Args }
  Add-ShellAlias '-na' { & bun add @Args }
  Add-ShellAlias '-nb' { & bun build @Args }
  Add-ShellAlias '-nc' { & bun create @Args }
  Add-ShellAlias '-nci' { & bun ci @Args }
  Add-ShellAlias '-ncl' { & bun clean @Args }
  Add-ShellAlias '-nf' { & bun fmt @Args }
  Add-ShellAlias '-nff' { & bun format @Args }
  Add-ShellAlias '-ni' { & bun install @Args }
  Add-ShellAlias '-nl' { & bun link @Args }
  Add-ShellAlias '-no' { & bun outdated @Args }
  Add-ShellAlias '-nr' { & bun run @Args }
  Add-ShellAlias '-nrm' { & bun remove @Args }
  Add-ShellAlias '-nt' { & bun test @Args }
  Add-ShellAlias '-nu' { & bun update @Args }
  Add-ShellAlias '-nup' { & bun upgrade @Args }
  Add-ShellAlias '-nw' { & bun why @Args }
  Add-ShellAlias '-nx' { & bun x @Args }
}

Add-ShellAlias '-v' { & nvim @Args }

function Test-NucleusPythonScopeActive {
  return (-not [string]::IsNullOrWhiteSpace($env:VIRTUAL_ENV)) -or (-not [string]::IsNullOrWhiteSpace($env:CONDA_PREFIX))
}

function Invoke-NucleusPythonScopedTool {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ToolName,

    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ToolArguments
  )

  if (-not (Test-NucleusPythonScopeActive)) {
    return $false
  }

  # check-suppress:suppression_doc: tool-availability guard -- tool may not be installed in venv
  $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $application) {
    return $false
  }

  & $application.Source @ToolArguments
  return $true
}

# Intercept python invocations: pass through only to the
# WinGet-managed Python installed by this repo on Windows
# (Python.Python.3.13 at %LOCALAPPDATA%\Programs\Python\Python313\python.exe).
# Everything else triggers the educational ban message.
function python {
  if (Invoke-NucleusPythonScopedTool -ToolName "python" @Args) {
    return
  }
  if ($IsWindows) {
    # Pass through only to the WinGet-managed Python from this repo.
    $nucleusPythonPath = Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"
    if (Test-Path $nucleusPythonPath) {
      & $nucleusPythonPath @Args
      return
    }
  }
  Write-Warning "shell: system-wide Python is banned to prevent accidental modifications."
  Write-Warning "         Use one of these approaches instead:"
  Write-Warning "         - nix develop     (activate project devShell with scoped Python)"
  Write-Warning "         - uv run <cmd>    (run Python via uv package manager)"
  Write-Warning "         - uv venv         (create per-project venv managed by uv)"
  $venvHint = if ($IsWindows) { '.\venv\Scripts\python' } else { './venv/bin/python' }
  Write-Warning "         - $venvHint (use pre-existing project venv)"
  return 1
}
# Intercept python3 invocations: route through the python wrapper.
# On Windows there is no python3.exe (only python.exe); on POSIX hosts the
# resolution chain is identical, so both platforms share this function.
function python3 {
  if (Invoke-NucleusPythonScopedTool -ToolName "python3" @Args) {
    return
  }
  python @Args
}
function pip {
  if (Invoke-NucleusPythonScopedTool -ToolName "pip" @Args) {
    return
  }
  Write-Warning "shell: system-wide pip is banned to prevent breaking system dependencies."
  Write-Warning "         Use one of these approaches instead:"
  Write-Warning "         - nix develop     (activate project devShell with scoped Python+pip)"
  Write-Warning "         - uv pip install  (use uv to manage project dependencies)"
  Write-Warning "         - uv venv         (create per-project venv managed by uv)"
  $venvHint = if ($IsWindows) { '.\venv\Scripts\pip' } else { './venv/bin/pip' }
  Write-Warning "         - $venvHint (use pre-existing project venv)"
  return 1
}
function pip3 {
  if (Invoke-NucleusPythonScopedTool -ToolName "pip3" @Args) {
    return
  }
  pip @Args
}

# Intercept npm/npx/node/corepack invocations.
# These tools are NOT installed by this repository. The sole JS runtime
# and package manager is bun.  Users who separately installed Node.js
# should use bun equivalents instead.
function npm {
  Write-Warning "shell: system-wide npm is not used in this environment."
  Write-Warning "         Use bun equivalents instead:"
  Write-Warning "         - bun install     (install packages)"
  Write-Warning "         - bun add <pkg>   (add a dependency)"
  Write-Warning "         - bun x <cmd>     (run one-shot package commands, replaces npx)"
  Write-Warning "         - bun run         (run package.json scripts)"
  Write-Warning "         Shell shortcuts -n* (bun) also work."
  return 1
}
function npx {
  Write-Warning "shell: system-wide npx is not used in this environment."
  Write-Warning "         Use bun x <cmd> for one-shot package execution instead."
  return 1
}
function node {
  # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- intentional: shadows native node; warns to use bun equivalents
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
  param()
  Write-Warning "shell: system-wide Node.js is not used in this environment."
  Write-Warning "         Use bun as the JavaScript runtime instead:"
  Write-Warning "         - bun <script>   (run a script)"
  Write-Warning "         - bun run        (run package.json scripts)"
  return 1
}
function corepack {
  Write-Warning "shell: corepack is not used in this environment."
  Write-Warning "         Use bun for package management instead."
  return 1
}

# Route managed development tools through an active direnv context, a
# rust-toolchain.toml project context (cargo/rustc only), or the
# user-scoped fallback toolchain for unmanaged repositories.
function Invoke-NucleusManagedDevTool {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ToolName,

    [Parameter(Mandatory = $false)]
    [string]$FallbackBinDirectory,

    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ToolArguments
  )

  # On Windows, the managed dev tools are only present on PATH inside an
  # active context (direnv devShell or rust-toolchain.toml project).  If
  # the tool is not on PATH at all, no context can satisfy the call and the
  # caller prints the educational ban message.
  # check-suppress:suppression_doc: presence probe -- tool may be absent; conditional branch handles the result immediately.
  $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($IsWindows -and $null -eq $application) {
    return $false
  }

  if ($env:DIRENV_DIR) {
    # check-suppress:suppression_doc: tool-availability guard -- tool may not be in direnv PATH
    if ($null -ne $application) {
      & $application.Source @ToolArguments
      return $true
    }
  }

  # rust-toolchain.toml in the current directory → project context
  # for cargo/rustc.  rustup (default none) reads the toolchain file
  # and routes cargo/rustc to the pinned toolchain so project builds
  # work without a full devShell or direnv context.
  if ($ToolName -in @('cargo', 'rustc') -and (Test-Path -Path (Join-Path (Get-Location).Path 'rust-toolchain.toml') -PathType Leaf)) {
    # check-suppress:suppression_doc: tool-availability guard -- tool may not be in project context
    if ($null -ne $application) {
      & $application.Source @ToolArguments
      return $true
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackBinDirectory)) {
    $fallbackToolPath = Join-Path $FallbackBinDirectory $ToolName
    if (Test-Path -Path $fallbackToolPath -PathType Leaf) {
      & $fallbackToolPath @ToolArguments
      return $true
    }
  }

  return $false
}

# System-wide build tool block: redirect bun/cargo/rustc/uv to warnings.
# These tools are installed globally for system package management only.
# When DIRENV_DIR is set, a direnv environment (devShell) is active.
# When a rust-toolchain.toml exists in the current directory, cargo/rustc
# pass through to the rustup shim.  Otherwise, fall back to the managed
# default toolchain installed by apply (POSIX-only; Windows keeps the
# user-scoped managed PATH instead, so no separate fallback bin root).
function bun {
  $fallbackBinDirectory = if ($IsWindows) { $null } else { "${NUCLEUS_DEFAULT_DEV_TOOLS}/bin" }
  if (Invoke-NucleusManagedDevTool -ToolName "bun" -FallbackBinDirectory $fallbackBinDirectory @Args) {
    return
  }
  Write-Warning "shell: managed bun is unavailable right now."
  Write-Warning "         For development, use one of these managed entrypoints:"
  Write-Warning "         - Enter a project directory with .envrc (direnv auto-loads the devShell)"
  Write-Warning "         - Or use the user-scoped default toolchain installed by nucleus apply"
  Write-Warning "         Shell shortcuts -n* (bun) also work inside a devShell."
  return 1
}
function cargo {
  $fallbackBinDirectory = if ($IsWindows) { $null } else { "${NUCLEUS_DEFAULT_DEV_TOOLS}/bin" }
  if (Invoke-NucleusManagedDevTool -ToolName "cargo" -FallbackBinDirectory $fallbackBinDirectory @Args) {
    return
  }
  Write-Warning "shell: managed cargo is unavailable right now."
  Write-Warning "         For Rust development, use one of these managed entrypoints:"
  Write-Warning "         - Enter a project directory with .envrc (direnv auto-loads the devShell)"
  Write-Warning "         - Or add a rust-toolchain.toml file to this directory"
  return 1
}
function rustc {
  $fallbackBinDirectory = if ($IsWindows) { $null } else { "${NUCLEUS_DEFAULT_DEV_TOOLS}/bin" }
  if (Invoke-NucleusManagedDevTool -ToolName "rustc" -FallbackBinDirectory $fallbackBinDirectory @Args) {
    return
  }
  Write-Warning "shell: managed rustc is unavailable right now."
  Write-Warning "         For Rust development, use one of these managed entrypoints:"
  Write-Warning "         - Enter a project directory with .envrc (direnv auto-loads the devShell)"
  Write-Warning "         - Or add a rust-toolchain.toml file to this directory"
  return 1
}
function uv {
  $fallbackBinDirectory = if ($IsWindows) { $null } else { "${NUCLEUS_DEFAULT_DEV_TOOLS}/bin" }
  if (Invoke-NucleusManagedDevTool -ToolName "uv" -FallbackBinDirectory $fallbackBinDirectory @Args) {
    return
  }
  Write-Warning "shell: managed uv is unavailable right now."
  Write-Warning "         For Python development, use one of these managed entrypoints:"
  Write-Warning "         - Enter a project directory with .envrc (direnv auto-loads the devShell)"
  Write-Warning "         - Or use the user-scoped default toolchain installed by nucleus apply"
  return 1
}

# --- nucleus-* argument completers ---
# Register argument completers for all nucleus commands to provide
# tab-completion for subcommands, flags, and dynamic values.

# Helper: resolve the nucleus repo root for dynamic completions.
function Resolve-NucleusRepoRoot {
  if ($env:NUCLEUS_REPO_ROOT) {
    return $env:NUCLEUS_REPO_ROOT
  }
  # check-suppress:suppression_doc: repo-membership probe -- may run outside the nucleus repo
  $gitRoot = git rev-parse --show-toplevel 2>$null
  if ($gitRoot -and (Test-Path (Join-Path $gitRoot "src/flake.nix"))) {
    return $gitRoot
  }
  # Windows: profile functions are invoked via apply.ps1 which sets
  # NUCLEUS_REPO_ROOT; outside the repo no fallback exists.
  if ($IsWindows) {
    throw "Resolve-NucleusRepoRoot: NUCLEUS_REPO_ROOT not set; run via apply.ps1"
  }
  return $null
}

if ($IsWindows) {
  function Invoke-NucleusRepoScript {
    param(
      [Parameter(Mandatory = $true)]
      [string]$ScriptRelativePath,
      [Parameter(ValueFromRemainingArguments = $true)]
      [object[]]$ScriptArguments
    )
    $repoRoot = Resolve-NucleusRepoRoot
    $scriptPath = Join-Path $repoRoot $ScriptRelativePath
    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
      throw "managed script not found at $scriptPath"
    }
    & $scriptPath @ScriptArguments
  }
  function nucleus-check-pwsh {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\check-pwsh.ps1' @Args
  }
  function nucleus-check-sh {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\check-sh.ps1' @Args
  }
  function nucleus-ai {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\ai.ps1' @Args
  }
  function nucleus-apply {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    $repoRoot = Resolve-NucleusRepoRoot
    $scriptPath = Join-Path $repoRoot 'src\hosts\Windows\apply.ps1'
    $moduleDir = Join-Path $repoRoot 'src\platforms\Windows\modules'
    $username = [System.Environment]::UserName
    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
      throw "nucleus-apply: script not found at $scriptPath"
    }
    & $scriptPath -ModuleDir $moduleDir -Users @($username) @Args
  }
  function nucleus-cloud-setup {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\cloud-setup.ps1' @Args
  }
  function nucleus-config {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\config.ps1' @Args
  }
  function nucleus-gc {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\gc.ps1' @Args
  }
  function nucleus-health-check {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\health-check.ps1' @Args
  }
  function nucleus-replica-sync {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\replica-sync.ps1' @Args
  }
  function nucleus-replica-reset {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\replica-reset.ps1' @Args
  }
  function nucleus-update {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\update.ps1' @Args
  }
  function nucleus-bootstrap {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\bootstrap.ps1' @Args
  }
  function nucleus-vm {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\vm.ps1' @Args
  }
  function nucleus-bump-lockfile {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\bump-lockfile.ps1' @Args
  }
  function nucleus-svc {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\svc.ps1' @Args
  }
  function nucleus-gs-pdf-opt {
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- intentional: wrapper function name is the fixed nucleus CLI contract
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param()
    Invoke-NucleusRepoScript 'scripts\gs-pdf-opt.ps1' @Args
  }
}

$nucleusSvcCommands = @('list', 'status', 'start', 'stop', 'restart', 'enable', 'disable', 'endpoint', 'logs', 'log-paths', 'log-config')
$nucleusConfigCommands = @('get', 'set', 'list')

Register-ArgumentCompleter -CommandName nucleus-svc -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $fakeBoundParameters  # check-suppress:suppression_doc: parameter metadata variables, declared for introspection
  $nucleusSvcCommands | Where-Object { $_ -like "$wordToComplete*" }
  if ($commandAst.CommandElements.Count -ge 2) {
    $prev = $commandAst.CommandElements[1].Value
    if ($nucleusSvcCommands -contains $prev) {
      # Complete service names by reading services.json
      $repoRoot = Resolve-NucleusRepoRoot
      if ($repoRoot) {
        $svcJson = Join-Path $repoRoot "src/modules/services.json"
        if (Test-Path $svcJson) {
          Get-Content $svcJson | ConvertFrom-Json | Get-Member -MemberType NoteProperty |
            Select-Object -ExpandProperty Name | Where-Object { $_ -like "$wordToComplete*" }
        }
      }
    }
  }
  @('--help', '--json') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-config -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: parameter metadata variables, declared for introspection
  $nucleusConfigCommands | Where-Object { $_ -like "$wordToComplete*" }
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-gc -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: parameter metadata variables, declared for introspection
  @(
    '--help', '--dry-run', '--no-dry-run',
    '--tool-cache-gc', '--no-tool-cache-gc',
    '--hm-gc', '--no-hm-gc',
    '--nix-gc', '--no-nix-gc',
    '--ollama-gc', '--no-ollama-gc',
    '--wallpaper-gc', '--no-wallpaper-gc',
    '--vm-gc', '--no-vm-gc',
    '--log-gc', '--no-log-gc',
    '--log-max-size', '--log-max-files', '--log-compress',
    '--expiry', '--hm-expiry', '--nix-expiry'
  ) | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-health-check -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--min-free-bytes', '--secret-health', '--no-secret-health', '--log-health') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-update -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--flake', '--no-flake', '--brew', '--no-brew', '--sops', '--no-sops') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-check -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--format', '--online') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-ai -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  if ($IsWindows) {
    # Windows nucleus-ai exposes sync-only flags; see scripts/ai.ps1 params.
    @('--help', '--dry-run', '--ollama-profile', '--gc-only', '--no-gc-only') |
      Where-Object { $_ -like "$wordToComplete*" }
  } else {
    # POSIX nucleus-ai exposes subcommands; see scripts/ai.sh usage.
    @('--help', 'sync', 'list', 'status', 'endpoint', 'config') |
      Where-Object { $_ -like "$wordToComplete*" }
  }
}

Register-ArgumentCompleter -CommandName nucleus-replica-sync -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--dry-run', '--replica-id', '--repo-root') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-replica-reset -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--dry-run', '--replica-id', '--repo-root') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-bootstrap -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--apply', '--no-apply', '--ai-sync', '--no-ai-sync',
    '--replica-sync', '--no-replica-sync', '--target-user') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-cloud-setup -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--apply', '--no-apply') | Where-Object { $_ -like "$wordToComplete*" }
}

$nucleusVmCommands = @('setup', 'list', 'status', 'start', 'stop', 'upgrade', 'reset', 'gc')
$nucleusVmSetupFlags = @('--help', '--dry-run', '--gc', '--no-gc',
  '--mido-patch-file', '--mido-script',
  '--windows-iso', '--no-windows-iso',
  '--windows-iso-source', '--no-windows-iso-source',
  '--windows-iso-retries',
  '--headful', '--no-headful',
  '--vm-dir-override', '--repo-root',
  '--accelerator')

Register-ArgumentCompleter -CommandName nucleus-vm -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  $nucleusVmCommands | Where-Object { $_ -like "$wordToComplete*" }
  if ($commandAst.CommandElements.Count -ge 2) {
    $subcommand = $commandAst.CommandElements[1].Value
    if ($subcommand -eq 'setup') {
      $nucleusVmSetupFlags | Where-Object { $_ -like "$wordToComplete*" }
    }
  }
  @('--help', '--json') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-apply -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--ai-sync', '--no-ai-sync',
    '--replica-sync', '--no-replica-sync',
    '--vm-setup', '--no-vm-setup',
    '--target-user', '--username') |
    Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-bump-lockfile -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help', '--sections', '--verify') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-check-packer -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-check-pwsh -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-check-sh -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-service-watchdog -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-gs-pdf-opt -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName nucleus-test -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
  $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters  # check-suppress:suppression_doc: completer callback params are signature-required but unused
  @('--help') | Where-Object { $_ -like "$wordToComplete*" }
}
