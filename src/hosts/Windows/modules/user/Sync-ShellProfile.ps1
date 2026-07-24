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

  $managedBlock = @($managedBlockStart) + $prependLines + $appendLines + @(
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if (Get-Command direnv -ErrorAction SilentlyContinue) {'
    '  (& direnv hook pwsh) | Out-String | Invoke-Expression'
    '}'
    # Load rclone config passphrase from materialized secret for automatic config
    # file encryption in interactive and scripted rclone invocations.
    # WHY conditional: secret file may be absent before apply has materialized it.
    '$_rclonePassFile = Join-Path $HOME ".config\nucleus\secrets\rclone-config-pass"'
    'if (Test-Path -Path $_rclonePassFile -PathType Leaf) {'
    # check-suppress:suppression_doc: file may not exist yet (first provision); absence is expected and handled downstream.
    '  $env:RCLONE_CONFIG_PASS = (Get-Content -Path $_rclonePassFile -Raw -ErrorAction SilentlyContinue).Trim()'
    # check-suppress:suppression_doc: resource may already be released; idempotent cleanup, not error swallowing.
    '  Remove-Variable -Name _rclonePassFile -ErrorAction SilentlyContinue'
    '}'
    # PSReadLine: predictive history completion + menu-style tab expansion.
    # Guards with module availability probe so the profile is safe on older hosts.
    'if (Get-Module -ListAvailable -Name PSReadLine) {'
    '  Import-Module PSReadLine'
    '  Set-PSReadLineOption -PredictionSource History'
    '  Set-PSReadLineOption -PredictionViewStyle ListView'
    '  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete'
    '  Set-PSReadLineOption -HistoryNoDuplicates'
    '  Set-PSReadLineOption -AddToHistoryHandler {'
    '    param($line)'
    '    $line -notmatch ''^\s'''
    '  }'
    '}'
    # zoxide: smart directory navigation learned from visit history.
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if (Get-Command zoxide -ErrorAction SilentlyContinue) {'
    '  Invoke-Expression (& zoxide init powershell | Out-String)'
    '}'
    # Starship prompt: cross-shell prompt with git/nix/status info.
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if (Get-Command starship -ErrorAction SilentlyContinue) {'
    '  Invoke-Expression (& starship init powershell | Out-String)'
    '}'
    # fzf: fuzzy history search on Ctrl+R via a PSReadLine key handler.
    # Reads the PSReadLine history file directly so all sessions are searchable.
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if ((Get-Command fzf -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name PSReadLine)) {'
    '  Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock {'
    '    $line = $null'
    '    $cursor = $null'
    '    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)'
    '    $histFile = (Get-PSReadLineOption).HistorySavePath'
    # check-suppress:suppression_doc: file may not exist yet (first provision); absence is expected and handled downstream.
    '    $selected = Get-Content -Path $histFile -ErrorAction SilentlyContinue |'
    '      Where-Object { $_ } | Sort-Object -Unique |'
    '      & fzf --tac --no-sort --height 40% --query $line'
    '    if ($LASTEXITCODE -eq 0 -and $selected) {'
    '      [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()'
    '      [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)'
    '    }'
    '  }'
    '}'
    # AI agent session detection: suppress pay-respects when VSCODE_AGENT,
    # CLAUDECODE, etc. are set.
    # Source of truth for env var names: src/modules/agent-env-vars.nix.
    'function Test-NucleusAgentSession {'
    '  # Standard AI agent environment variables'
    '  if (Test-Path env:AGENT) { return $true }'
    '  if (Test-Path env:AI_AGENT) { return $true }'
    '  # Tool-specific environment variables'
    '  if (Test-Path env:VSCODE_AGENT) { return $true }'
    '  if (Test-Path env:CLAUDECODE) { return $true }'
    '  if (Test-Path env:CLAUDE_CODE) { return $true }'
    '  if (Test-Path env:CURSOR_AGENT) { return $true }'
    '  if (Test-Path env:GOOSE_TERMINAL) { return $true }'
    '  if (Test-Path env:CLINE_ACTIVE) { return $true }'
    '  if (Test-Path env:GEMINI_CLI) { return $true }'
    '  if (Test-Path env:CODEX_SANDBOX) { return $true }'
    '  if (Test-Path env:TRAE_AI_SHELL_ID) { return $true }'
    '  if (Test-Path env:AUGMENT_AGENT) { return $true }'
    '  if (Test-Path env:NUCLEUS_AGENT_SESSION) { return $true }'
    '  if (Test-Path env:OPENCODE_CLIENT) { return $true }'
    '  # Devin filesystem marker'
    '  if (Test-Path "/opt/.devin") { return $true }'
    '  if (Test-Path "C:\opt\.devin") { return $true }'
    '  return $false'
    '}'
    # Interactive-feature suppression in AI agent sessions:
    # disable PSReadLine, flatten prompt, suppress confirm/warn prompts.
    'if (Test-NucleusAgentSession) {'
    # check-suppress:suppression_doc: resource may already be released; idempotent cleanup, not error swallowing.
    '  Remove-Module PSReadLine -ErrorAction SilentlyContinue'
    '  $ConfirmPreference = ''None'''
    '  $WarningActionPreference = ''SilentlyContinue'''
    '  function prompt { "PS> " }'
    '}'
    # pay-respects: register correction hook in interactive and non-agent
    # sessions only.
    # WHY non-interactive guard: agent-spawned or scripted PowerShell sessions
    # would block on the interactive prompt with no user to respond.
    # WHY AI agent guard: AI coding agents spawn PowerShell sessions that are
    # technically UserInteractive but cannot respond to prompts.
    # -ErrorAction SilentlyContinue is intentional: pay-respects may be absent
    # on first-provision before cargo-binstall setup has run; the if-guard
    # checks the result immediately so no failure is silently swallowed.
    # In PowerShell, functions take higher precedence than aliases in command
    # lookup, so the `f` function defined by pay-respects --alias is not
    # shadowed by any alias of the same name (unlike zsh where aliases shadow
    # functions).
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if ([Environment]::UserInteractive -and -not (Test-NucleusAgentSession) -and (Get-Command pay-respects -ErrorAction SilentlyContinue)) {'
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
    # check-suppress:suppression_doc: expected stderr from git rev-parse probe outside git repos; branch handles the non-repo case.
    '  $gitDirOutput = & git -C $RepositoryRoot rev-parse --git-dir 2>$null'
    '  if (-not $gitDirOutput) {'
    '    return $false'
    '  }'
    '  $gitDir = ($gitDirOutput | Out-String).Trim()'
    '  if (-not [System.IO.Path]::IsPathRooted($gitDir)) {'
    '    $gitDir = Join-Path -Path $RepositoryRoot -ChildPath $gitDir'
    '  }'
    '  $hookDir = Join-Path -Path $gitDir -ChildPath "hooks"'
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
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {'
    '    return'
    '  }'
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  if (-not (Get-Command prek -ErrorAction SilentlyContinue)) {'
    '    return'
    '  }'
    '  # git rev-parse is a repo-membership probe here; suppress the expected'
    '  # stderr from non-repository directories and branch on the result.'
    # check-suppress:suppression_doc: expected stderr from git rev-parse probe outside git repos; branch handles the non-repo case.
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
    # LLVM/Clang: add LLVM bin directory to PATH for the current session so
    # newly provisioned hosts can run clang/ld.lld immediately.
    '$llvmBinDir = "' + (Get-NucleusLLVMBinDir) + '"'
    'if ((Test-Path $llvmBinDir) -and ($env:PATH -notlike "*$llvmBinDir*")) {'
    '  $env:PATH = "$env:PATH;$llvmBinDir"'
    '}'
    # CC/CXX/LD are set at Machine scope via system/env.dsc.yml for
    # all-process visibility.  Source: src/modules/lib/env-catalog.nix.
    # Git shell aliases — mirrors src/modules/shell/aliases.nix
    # Naming conventions:
    # - Prefix = base git command (all `git log` aliases start with `-gl`).
    # - `-gca*` = amend (every alias starting with `-gca` expands to `git commit --amend ...`).
    # - No casing distinction (case-insensitive on Windows).
    # - Double letter = more: more verbose, more forceful, or full form.
    # - All options MUST use long form (--patch, --all, --message, etc.). See aliases.nix header.
    'function -g { & git @Args }'
    'function -ga { & git add @Args }'
    'function -gap { & git add --patch @Args }'
    'function -gb { & git branch @Args }'
    'function -gba { & git branch --all @Args }'
    'function -gbd { & git branch --delete @Args }'
    'function -gbdd { & git branch --delete --force @Args }'
    'function -gbm { & git branch --move @Args }'
    'function -gc { & git commit @Args }'
    'function -gca { & git commit --amend @Args }'
    'function -gcaa { & git commit --all --amend @Args }'
    'function -gcam { & git commit --amend --message @Args }'
    'function -gcl { & git clone @Args }'
    'function -gclean { & git clean --force -d --dry-run @Args }'
    'function -gcleanf { & git clean --force -d @Args }'
    'function -gcm { & git commit --message @Args }'
    'function -gcma { & git commit --all --message @Args }'
    'function -gco { & git checkout @Args }'
    'function -gcob { & git checkout --branch @Args }'
    'function -gd { & git diff @Args }'
    'function -gdc { & git diff --cached @Args }'
    'function -gds { & git diff --stat @Args }'
    'function -gf { & git fetch @Args }'
    'function -gfa { & git fetch --all @Args }'
    'function -gff { & git fetch --force @Args }'
    'function -gg { & git grep @Args }'
    'function -gl { & git log --oneline --decorate --graph @Args }'
    'function -gla { & git log --oneline --decorate --graph --all @Args }'
    'function -gll { & git log --decorate --graph --show-signature --stat @Args }'
    'function -glla { & git log --decorate --graph --show-signature --stat --all @Args }'
    'function -glp { & git log --oneline --decorate --graph --patch @Args }'
    'function -gls { & git log --oneline --decorate --graph --stat @Args }'
    'function -gm { & git merge @Args }'
    'function -gma { & git merge --abort @Args }'
    'function -gmnff { & git merge --no-ff @Args }'
    'function -gp { & git push @Args }'
    'function -gpf { & git push --force-with-lease @Args }'
    'function -gpff { & git push --force @Args }'
    'function -gpl { & git pull @Args }'
    'function -gplf { & git pull --force @Args }'
    'function -gplo { & git pull origin @Args }'
    'function -gplr { & git pull --rebase @Args }'
    'function -gpo { & git push origin @Args }'
    'function -gr { & git remote @Args }'
    'function -grb { & git rebase @Args }'
    'function -grba { & git rebase --abort @Args }'
    'function -grbc { & git rebase --continue @Args }'
    'function -grbi { & git rebase --interactive @Args }'
    'function -grbm { & git rebase main @Args }'
    'function -grbo { & git rebase --onto @Args }'
    'function -grbs { & git rebase --skip @Args }'
    'function -grev { & git revert @Args }'
    'function -grs { & git reset @Args }'
    'function -grsh { & git reset --soft HEAD~ @Args }'
    'function -grshh { & git reset --hard HEAD~ @Args }'
    'function -grv { & git remote --verbose @Args }'
    'function -gs { & git status --short --branch @Args }'
    'function -gsh { & git show @Args }'
    'function -gss { & git status @Args }'
    'function -gst { & git stash push @Args }'
    'function -gstd { & git stash drop @Args }'
    'function -gstl { & git stash list @Args }'
    'function -gstp { & git stash pop @Args }'
    'function -gstsh { & git stash show --patch @Args }'
    'function -gsw { & git switch @Args }'
    'function -gswc { & git switch --create @Args }'
    'function -gt { & git tag @Args }'
    'function -gtd { & git tag --delete @Args }'
    'function -gtl { & git tag --list @Args }'
    # --- Ghostscript PDF optimization aliases ---
    'function Invoke-NucleusGhostscript {'
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }'
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }'
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }'
    '  throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"'
    '}'
    # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
    # newer PDF compatibility target is released by Ghostscript.
    'function -gs-pdf-opt-default  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default  -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function -gs-pdf-opt-prepress { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function -gs-pdf-opt-printer  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer  -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function -gs-pdf-opt-ebook    { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook    -dNOPAUSE -dQUIET -dBATCH @Args }'
    'function -gs-pdf-opt-screen   { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen   -dNOPAUSE -dQUIET -dBATCH @Args }'
    # la/ll: prefer eza for colour, icons, and extended metadata; fall back to
    # Get-ChildItem when eza is absent so the profile loads on unmanaged machines.
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if (Get-Command eza -ErrorAction SilentlyContinue) {'
    '  function -la { & eza --long --all @Args }'
    '  function -ll { & eza --long --all @Args }'
    '} else {'
    '  function -la { Get-ChildItem -Force @Args }'
    '  function -ll { Get-ChildItem -Force @Args }'
    '}'
    # bun shortcuts: mirrors -ni/-nr/-nx aliases in shell/aliases.nix on POSIX hosts.
    # Guarded so the profile loads safely on machines where bun is not yet installed.
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    'if (Get-Command bun -ErrorAction SilentlyContinue) {'
    '  function -ni { & bun install @Args }'
    '  function -nr { & bun run @Args }'
    '  function -nx { & bun x @Args }'
    '}'
    'function Resolve-NucleusRepoRoot {'
    '  if ($env:NUCLEUS_REPO_ROOT) {'
    '    return $env:NUCLEUS_REPO_ROOT'
    '  }'
    '  throw "Resolve-NucleusRepoRoot: NUCLEUS_REPO_ROOT not set; run via apply.ps1"'
    '}'
    'function Invoke-NucleusRepoScript {'
    '  param('
    '    [Parameter(Mandatory = $true)]'
    '    [string]$ScriptRelativePath,'
    '    [Parameter(ValueFromRemainingArguments = $true)]'
    '    [object[]]$ScriptArguments'
    '  )'
    '  $repoRoot = Resolve-NucleusRepoRoot'
    '  $scriptPath = Join-Path $repoRoot $ScriptRelativePath'
    '  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {'
    '    throw "managed script not found at $scriptPath"'
    '  }'
    '  & $scriptPath @ScriptArguments'
    '}'
    'function nucleus-check-pwsh {'
    '  Invoke-NucleusRepoScript ''scripts\check-pwsh.ps1'' @Args'
    '}'
    'function nucleus-check-sh {'
    '  Invoke-NucleusRepoScript ''scripts\check-sh.sh'' @Args'
    '}'
    'function nucleus-ai {'
    '  Invoke-NucleusRepoScript ''scripts\ai.ps1'' @Args'
    '}'
    'function nucleus-apply {'
    '  $repoRoot = Resolve-NucleusRepoRoot'
    '  $scriptPath = Join-Path $repoRoot ''src\hosts\Windows\apply.ps1'''
    '  $moduleDir = Join-Path $repoRoot ''src\hosts\Windows\modules'''
    '  $username = [System.Environment]::UserName'
    '  if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {'
    '    throw "nucleus-apply: script not found at $scriptPath"'
    '  }'
    '  & $scriptPath -ModuleDir $moduleDir -PrimaryUsername $username -Users @($username) @Args'
    '}'
    'function nucleus-cloud-setup {'
    '  Invoke-NucleusRepoScript ''scripts\cloud-setup.ps1'' @Args'
    '}'
    'function nucleus-config {'
    '  Invoke-NucleusRepoScript ''scripts\config.ps1'' @Args'
    '}'
    'function nucleus-gc {'
    '  Invoke-NucleusRepoScript ''scripts\gc.ps1'' @Args'
    '}'
    'function nucleus-health-check {'
    '  Invoke-NucleusRepoScript ''scripts\health-check.ps1'' @Args'
    '}'
    'function nucleus-replica-sync {'
    '  Invoke-NucleusRepoScript ''scripts\replica-sync.ps1'' @Args'
    '}'
    'function nucleus-replica-reset {'
    '  Invoke-NucleusRepoScript ''scripts\replica-reset.ps1'' @Args'
    '}'
    'function nucleus-update {'
    '  Invoke-NucleusRepoScript ''scripts\update.ps1'' @Args'
    '}'
    'function nucleus-bootstrap {'
    '  Invoke-NucleusRepoScript ''scripts\bootstrap.ps1'' @Args'
    '}'
    'function nucleus-vm {'
    '  Invoke-NucleusRepoScript ''scripts\vm.ps1'' @Args'
    '}'
    'function nucleus-bump-lockfile {'
    '  Invoke-NucleusRepoScript ''scripts\bump-lockfile.ps1'' @Args'
    '}'
    'function nucleus-svc {'
    '  Invoke-NucleusRepoScript ''scripts\svc.ps1'' @Args'
    '}'
    'function nucleus-gs-pdf-opt {'
    '  Invoke-NucleusRepoScript ''scripts\gs-pdf-opt.ps1'' @Args'
    '}'
    # --- nucleus-* argument completers ---
    '# Register argument completers for all nucleus commands to provide'
    '# tab-completion for subcommands, flags, and dynamic values.'
    ''
    '$nucleusSvcCommands = @(''list'', ''status'', ''start'', ''stop'', ''restart'', ''enable'', ''disable'', ''endpoint'', ''logs'', ''log-paths'', ''log-config'')'
    '$nucleusConfigCommands = @(''get'', ''set'', ''list'')'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-svc -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  $nucleusSvcCommands | Where-Object { $_ -like "$wordToComplete*" }'
    '  if ($commandAst.CommandElements.Count -ge 2) {'
    '    $prev = $commandAst.CommandElements[1].Value'
    '    if ($nucleusSvcCommands -contains $prev) {'
    '      $repoRoot = Resolve-NucleusRepoRoot'
    '      if ($repoRoot) {'
    '        $svcJson = Join-Path $repoRoot ''src/modules/services.json'''
    '        if (Test-Path $svcJson) {'
    '          Get-Content $svcJson | ConvertFrom-Json | Get-Member -MemberType NoteProperty |'
    '            Select-Object -ExpandProperty Name | Where-Object { $_ -like "$wordToComplete*" }'
    '        }'
    '      }'
    '    }'
    '  }'
    '  @(''--help'', ''--json'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-config -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  $nucleusConfigCommands | Where-Object { $_ -like "$wordToComplete*" }'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-gc -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @('
    '    ''--help'', ''--dry-run'', ''--no-dry-run'', '
    '    ''--tool-cache-gc'', ''--no-tool-cache-gc'', '
    '    ''--hm-gc'', ''--no-hm-gc'', '
    '    ''--nix-gc'', ''--no-nix-gc'', '
    '    ''--ollama-gc'', ''--no-ollama-gc'', '
    '    ''--wallpaper-gc'', ''--no-wallpaper-gc'', '
    '    ''--vm-gc'', ''--no-vm-gc'', '
    '    ''--log-gc'', ''--no-log-gc'', '
    '    ''--log-max-size'', ''--log-max-files'', ''--log-compress'', '
    '    ''--expiry'', ''--hm-expiry'', ''--nix-expiry'''
    '  ) | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-health-check -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--min-free-bytes'', ''--secret-health'', ''--no-secret-health'', ''--log-health'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-update -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--flake'', ''--no-flake'', ''--brew'', ''--no-brew'', ''--sops'', ''--no-sops'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-check -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--format'', ''--verify'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-ai -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--dry-run'', ''--ollama-profile'', ''--gc-only'', ''--no-gc-only'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-replica-sync -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--dry-run'', ''--replica-id'', ''--repo-root'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-replica-reset -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--dry-run'', ''--replica-id'', ''--repo-root'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-bootstrap -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--apply'', ''--no-apply'', ''--ai-sync'', ''--no-ai-sync'', '
    '    ''--replica-sync'', ''--no-replica-sync'', ''--target-user'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-cloud-setup -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--apply'', ''--no-apply'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    '$nucleusVmCommands = @(''setup'', ''list'', ''status'', ''start'', ''stop'', ''upgrade'', ''reset'', ''gc'')'
    '$nucleusVmSetupFlags = @(''--help'', ''--dry-run'', ''--gc'', ''--no-gc'',
    ''--mido-patch-file'', ''--mido-script'',
    ''--windows-iso'', ''--no-windows-iso'',
    ''--windows-iso-source'', ''--no-windows-iso-source'',
    ''--windows-iso-retries'',
    ''--headful'', ''--no-headful'',
    ''--vm-dir-override'', ''--repo-root'',
    ''--accelerator'')'

    ''
    'Register-ArgumentCompleter -CommandName nucleus-vm -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  $nucleusVmCommands | Where-Object { $_ -like "$wordToComplete*" }'
    '  if ($commandAst.CommandElements.Count -ge 2) {'
    '    $subcommand = $commandAst.CommandElements[1].Value'
    '    if ($subcommand -eq ''setup'') {'
    '      $nucleusVmSetupFlags | Where-Object { $_ -like "$wordToComplete*" }'
    '    }'
    '  }'
    '  @(''--help'', ''--json'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-apply -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--ai-sync'', ''--no-ai-sync'', '
    '    ''--replica-sync'', ''--no-replica-sync'', '
    '    ''--vm-setup'', ''--no-vm-setup'', '
    '    ''--target-user'', ''--username'') |'
    '    Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-bump-lockfile -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'', ''--sections'', ''--verify'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-check-packer -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-check-pwsh -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-check-sh -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-service-watchdog -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-gs-pdf-opt -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    ''
    'Register-ArgumentCompleter -CommandName nucleus-test -ScriptBlock {'
    '  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)'
    '  @(''--help'') | Where-Object { $_ -like "$wordToComplete*" }'
    '}'
    'function -v { & nvim @Args }'
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
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
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
    '# System-wide JS ecosystem ban: redirect npm/npx/node/corepack to warnings.'
    'function npm {'
    '  Write-Host "js-ban: system-wide npm is not used in this environment." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use bun equivalents instead:" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun install     (install packages)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun add <pkg>   (add a dependency)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun x <cmd>     (run one-shot package commands, replaces npx)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun run         (run package.json scripts)" -ForegroundColor Yellow >&2'
    '  Write-Host "         Shell shortcuts -ni/-nr/-nx also work." -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    'function npx {'
    '  Write-Host "js-ban: system-wide npx is not used in this environment." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use bun x <cmd> for one-shot package execution instead." -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    'function node {'
    '  Write-Host "js-ban: system-wide Node.js is not used in this environment." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use bun as the JavaScript runtime instead:" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun <script>   (run a script)" -ForegroundColor Yellow >&2'
    '  Write-Host "         - bun run        (run package.json scripts)" -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    'function corepack {'
    '  Write-Host "js-ban: corepack is not used in this environment." -ForegroundColor Yellow >&2'
    '  Write-Host "         Use bun for package management instead." -ForegroundColor Yellow >&2'
    '  return 1'
    '}'
    '# Route managed development tools through an active direnv context, a'
    '# rust-toolchain.toml project context (cargo/rustc only), or the managed'
    '# default shell environment for repositories without .envrc.'
    'function Invoke-NucleusManagedDevTool {'
    '  param('
    '    [Parameter(Mandatory = $true)]'
    '    [string]$ToolName,'
    '    [Parameter(ValueFromRemainingArguments = $true)]'
    '    [object[]]$ToolArguments'
    '  )'
    # check-suppress:suppression_doc: presence probe — tool may be absent; conditional branch handles the result immediately.
    '  $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1'
    '  if ($null -eq $application) {'
    '    return $false'
    '  }'
    '  # rust-toolchain.toml in the current directory → project context'
    '  # for cargo/rustc.'
    '  if ($ToolName -in @(''cargo'', ''rustc'') -and (Test-Path -Path (Join-Path (Get-Location).Path ''rust-toolchain.toml'') -PathType Leaf)) {'
    '    & $application.Source @ToolArguments'
    '    return $true'
    '  }'
    '  if ($env:DIRENV_DIR) {'
    '    & $application.Source @ToolArguments'
    '    return $true'
    '  }'
    '  return $false'
    '}'
    # System-wide build tool block: redirect bun/cargo/rustc/uv to warnings.
    # These tools are installed globally for system package management only.
    # When DIRENV_DIR is set, a direnv environment (devShell) is active.
    # When a rust-toolchain.toml exists in the current directory, cargo/rustc
    # pass through to the rustup shim.  Otherwise, use the managed default
    # shell environment so plain repos still have a safe baseline toolchain.
    # check-suppress:suppression_doc: Windows does not have a separate nix-direnv-backed fallback store
    # path in this workflow yet, so parity uses the user-scoped managed PATH
    # instead of a second binary install root.
    'function bun {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "bun" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed bun is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or use the managed default shell environment installed by apply.ps1" -ForegroundColor Yellow'
    '  Write-Host "         Shell shortcuts -ni/-nr/-nx also work inside a devShell." -ForegroundColor Yellow'
    '  return 1'
    '}'
    'function cargo {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "cargo" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed cargo is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or add a rust-toolchain.toml file to this directory" -ForegroundColor Yellow'
    '  return 1'
    '}'
    'function rustc {'
    '  if (Invoke-NucleusManagedDevTool -ToolName "rustc" @Args) {'
    '    return'
    '  }'
    '  Write-Host "shell: managed rustc is unavailable right now." -ForegroundColor Yellow'
    '  Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow'
    '  Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow'
    '  Write-Host "         - Or add a rust-toolchain.toml file to this directory" -ForegroundColor Yellow'
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
