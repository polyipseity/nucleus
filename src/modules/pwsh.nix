# PowerShell profile for POSIX hosts.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  # Fallback tool inventory matching shell.nix for repos without direnv/Nix hooks.
  defaultDevTools = pkgs.symlinkJoin {
    name = "default-dev-tools";
    paths = [
      pkgs.bun
      pkgs.prek
      pkgs.uv
    ];
  };

  agentEnv = import ./agent-env-vars.nix;

  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);
  pwshAnalyzerVersion = lockfile.pwsh.PSScriptAnalyzer or null;
  pwshYamlVersion = lockfile.pwsh."powershell-yaml" or null;

  envVars = import ./lib/env-vars.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  profileContent = ''
        # This file is managed by nucleus (src/modules/pwsh.nix).
        # Manual edits will be overwritten on the next `nix run .#apply`.

        # direnv: load per-directory environments defined in .envrc files.
        if (Get-Command direnv -ErrorAction SilentlyContinue) {
          (& direnv hook pwsh) | Out-String | Invoke-Expression
        }

        # Keep a user-scoped fallback toolchain available when the current project
        # does not provide a direnv/devShell entrypoint.
        $env:NUCLEUS_DEFAULT_DEV_BIN = "${defaultDevTools}/bin"
        $env:NUCLEUS_DEFAULT_DEV_ENV = "1"

        # Expose user-scope package manager bins so globally installed tools are
        # accessible in interactive sessions.
        #   bun install -g   -> ~\.bun\bin   (BUN_INSTALL_BIN default)
        #   cargo-binstall   -> ~\.cargo\bin (CARGO_HOME\bin default)
        #   uv tool install  -> ~\.local\bin (XDG_BIN_HOME default)
        # Guards prevent PATH growth when a directory does not exist yet.
        # Source: https://bun.sh/docs/cli/install#global-packages
        # Source: https://doc.rust-lang.org/cargo/commands/cargo-install.html
        # Source: https://docs.astral.sh/uv/reference/settings/#tool-bin-dir
        $__nucleusBinPaths = @(
          (Join-Path $HOME ".bun\bin"),
          (Join-Path $HOME ".cargo\bin"),
          (Join-Path $HOME ".local\bin")
        )
        foreach ($__nucleusBinPath in $__nucleusBinPaths) {
          if ((Test-Path $__nucleusBinPath) -and ($env:PATH -notlike "*$__nucleusBinPath*")) {
            $env:PATH = "$__nucleusBinPath;$env:PATH"
          }
        }
        Remove-Variable __nucleusBinPaths, __nucleusBinPath -ErrorAction SilentlyContinue

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
        if (Get-Command zoxide -ErrorAction SilentlyContinue) {
          Invoke-Expression (& zoxide init powershell | Out-String)
        }

        # Starship prompt: cross-shell prompt with git/nix/status info.
        if (Get-Command starship -ErrorAction SilentlyContinue) {
          Invoke-Expression (& starship init powershell | Out-String)
        }

        # LLVM/Clang toolchain defaults sourced from the centralized env var
        # catalog.  Shell-only on macOS; all-process on NixOS/Windows.
        # Source: src/modules/lib/env-vars.nix (CC, CXX, LD entries).
        $env:CC = "${envVars.catalog.CC.value}"
        $env:CXX = "${envVars.catalog.CXX.value}"
        $env:LD = "${envVars.catalog.LD.value}"

        # ---------------------------------------------------------------
        # AI agent session detection
        # ---------------------------------------------------------------
        # Environment variable names sourced from src/modules/agent-env-vars.nix.
        function Test-NucleusAgentSession {
    ${lib.concatStringsSep "\n" (
      map (v: "      if (Test-Path env:${v}) { return $true }") agentEnv.agentEnvVarNames
    )}
          if (Test-Path "${agentEnv.devinPosixPath}") { return $true }
          return $false
        }

        # ---------------------------------------------------------------
        # Interactive-feature suppression in AI agent sessions
        # ---------------------------------------------------------------
        # When an AI agent is detected, disable PSReadLine and other interactive
        # features that serve no purpose and clutter output in non-human sessions.
        if (Test-NucleusAgentSession) {
          Remove-Module PSReadLine -ErrorAction SilentlyContinue
          $ConfirmPreference = 'None'
          $WarningActionPreference = 'SilentlyContinue'
          function prompt { "PS> " }
        }

        # ---------------------------------------------------------------
        # pay-respects shell hook
        # ---------------------------------------------------------------
        # Only initialise in interactive, non-agent, and available sessions.
        # In non-interactive or AI agent sessions, pay-respects would block on
        # its interactive prompt with no user to respond.
        if ([Environment]::UserInteractive -and -not (Test-NucleusAgentSession) -and (Get-Command pay-respects -ErrorAction SilentlyContinue)) {
          iex (& pay-respects pwsh --alias | Out-String)
        }

        # prek: install repository-local Git hooks automatically the first time a
        # shell session enters a repo that opted into prek via prek.toml.
        # The hook first checks for the canonical generated shims so already-
        # provisioned repos stay quiet across new shell sessions, then falls back
        # to a per-session cache to avoid repeated installs after the first run.
        $global:__nucleusPrekCheckedRepos = @{}
        $global:__nucleusPrekInstallInProgress = $false
        function Test-PrekHooksInstalled {
          param(
            [Parameter(Mandatory = $true)]
            [string]$RepositoryRoot
          )

          # WHY git rev-parse: handles .git as file (submodules, worktrees) + directory.
          # Avoids silent failure when .git is a gitlink (file with gitdir: path).
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
          if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            return
          }
          if (-not (Get-Command prek -ErrorAction SilentlyContinue)) {
            return
          }

          # git rev-parse is a repo-membership probe here; suppress the expected
          # stderr from non-repository directories and branch on the result.
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
          if ($global:__nucleusPrekInstallInProgress) {
            return
          }
          if ($global:__nucleusPrekCheckedRepos.ContainsKey($repoRoot)) {
            return
          }
          if (Test-PrekHooksInstalled -RepositoryRoot $repoRoot) {
            $global:__nucleusPrekCheckedRepos[$repoRoot] = $true
            return
          }

          $global:__nucleusPrekInstallInProgress = $true
          Write-Host "prek: installing hooks in $repoRoot" -ForegroundColor Cyan
          Push-Location $repoRoot
          try {
            & prek install
            if ($LASTEXITCODE -ne 0) {
              throw "prek install failed with exit code $LASTEXITCODE"
            }

            $global:__nucleusPrekCheckedRepos[$repoRoot] = $true
          }
          catch {
            Write-Warning "prek: failed to install hooks in $repoRoot — $($_.Exception.Message)"
          }
          finally {
            $global:__nucleusPrekInstallInProgress = $false
            Pop-Location
          }
        }

        if (-not $global:__nucleusPrekPromptWrapped) {
          $global:__nucleusPrekPromptWrapped = $true
          $global:__nucleusPrekPreviousPrompt = if (Test-Path Function:\prompt) {
            (Get-Command prompt -CommandType Function).ScriptBlock
          } else {
            $null
          }

          function global:prompt {
            Invoke-PrekHookInstallIfNeeded
            if ($null -ne $global:__nucleusPrekPreviousPrompt) {
              & $global:__nucleusPrekPreviousPrompt
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
        if ((Get-Command fzf -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name PSReadLine)) {
          Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock {
            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            $histFile = (Get-PSReadLineOption).HistorySavePath
            $selected = Get-Content -Path $histFile -ErrorAction SilentlyContinue |
              Where-Object { $_ } | Sort-Object -Unique |
              & fzf --tac --no-sort --height 40% --query $line
            if ($LASTEXITCODE -eq 0 -and $selected) {
              [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
              [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)
            }
          }
        }

        function -g { & git @Args }
        function -ga { & git add @Args }
        function -gb { & git branch @Args }
        function -gc { & git commit @Args }
        function -gca { & git commit --amend @Args }
        function -gcl { & git clone @Args }
        function -gco { & git checkout @Args }
        function -gd { & git diff @Args }
        function -gf { & git fetch @Args }
        function -gl { & git log --oneline --decorate --graph @Args }
        function -gp { & git push @Args }
        function -gpl { & git pull @Args }
        # git status in short format with branch info, restored from git history.
        function -gs { & git status -sb @Args }

        function Invoke-NucleusGhostscript {
          if (Get-Command gs -ErrorAction SilentlyContinue) {
            & gs @Args
            return
          }
          if (Get-Command gswin64c -ErrorAction SilentlyContinue) {
            & gswin64c @Args
            return
          }
          if (Get-Command gswin32c -ErrorAction SilentlyContinue) {
            & gswin32c @Args
            return
          }
          throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
        }

        # Ghostscript PDF optimization presets.
        # CompatibilityLevel is pinned to 2.0 (latest as of 2026-05); bump when a
        # newer PDF compatibility target is released by Ghostscript.
        function -gs-pdf-opt-default  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default  -dNOPAUSE -dQUIET -dBATCH @Args }
        function -gs-pdf-opt-ebook    { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/ebook    -dNOPAUSE -dQUIET -dBATCH @Args }
        function -gs-pdf-opt-prepress { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH @Args }
        function -gs-pdf-opt-printer  { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/printer  -dNOPAUSE -dQUIET -dBATCH @Args }
        function -gs-pdf-opt-screen   { Invoke-NucleusGhostscript -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/screen   -dNOPAUSE -dQUIET -dBATCH @Args }
        function -gst { & git status @Args }
        function -gsw { & git switch @Args }

        # la/ll: prefer eza for colour, icons, and extended metadata; fall back to
        # Get-ChildItem when eza is absent so the profile loads on unmanaged machines.
        if (Get-Command eza -ErrorAction SilentlyContinue) {
          function -la { & eza -la @Args }
          function -ll { & eza -la @Args }
        } else {
          function -la { Get-ChildItem -Force @Args }
          function -ll { Get-ChildItem -Force @Args }
        }

        function -ni { & bun install @Args }
        function -nr { & bun run @Args }
        function -nx { & bun x @Args }

        function -v { & nvim @Args }

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

          $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($null -eq $application) {
            return $false
          }

          & $application.Source @ToolArguments
          return $true
        }

        # System-wide Python ban: redirect python/pip to warnings so users are
        # guided to scoped alternatives instead of modifying the system environment.
        function python {
          if (Invoke-NucleusPythonScopedTool -ToolName "python" @Args) {
            return
          }
          Write-Host "shell: system-wide Python is banned to prevent accidental modifications." -ForegroundColor Yellow
          Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow
          Write-Host "         - nix develop     (activate project devShell with scoped Python)" -ForegroundColor Yellow
          Write-Host "         - uv run <cmd>    (run Python via uv package manager)" -ForegroundColor Yellow
          Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow
          Write-Host "         - ./venv/bin/python (use pre-existing project venv)" -ForegroundColor Yellow
          return 1
        }
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
          Write-Host "shell: system-wide pip is banned to prevent breaking system dependencies." -ForegroundColor Yellow
          Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow
          Write-Host "         - nix develop     (activate project devShell with scoped Python+pip)" -ForegroundColor Yellow
          Write-Host "         - uv pip install  (use uv to manage project dependencies)" -ForegroundColor Yellow
          Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow
          Write-Host "         - ./venv/bin/pip  (use pre-existing project venv)" -ForegroundColor Yellow
          return 1
        }
        function pip3 {
          if (Invoke-NucleusPythonScopedTool -ToolName "pip3" @Args) {
            return
          }
          pip @Args
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

          if ($env:DIRENV_DIR) {
            $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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
            $application = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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
        # default toolchain installed by apply.
        function bun {
          if (Invoke-NucleusManagedDevTool -ToolName "bun" -FallbackBinDirectory $env:NUCLEUS_DEFAULT_DEV_BIN @Args) {
            return
          }
          Write-Host "shell: managed bun is unavailable right now." -ForegroundColor Yellow
          Write-Host "         For development, use one of these managed entrypoints:" -ForegroundColor Yellow
          Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow
          Write-Host "         - Or use the user-scoped default toolchain installed by nucleus apply" -ForegroundColor Yellow
          Write-Host "         Shell shortcuts -ni/-nr/-nx also work inside a devShell." -ForegroundColor Yellow
          return 1
        }
        function cargo {
          if (Invoke-NucleusManagedDevTool -ToolName "cargo" -FallbackBinDirectory $env:NUCLEUS_DEFAULT_DEV_BIN @Args) {
            return
          }
          Write-Host "shell: managed cargo is unavailable right now." -ForegroundColor Yellow
          Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow
          Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow
          Write-Host "         - Or add a rust-toolchain.toml file to this directory" -ForegroundColor Yellow
          return 1
        }
        function rustc {
          if (Invoke-NucleusManagedDevTool -ToolName "rustc" -FallbackBinDirectory $env:NUCLEUS_DEFAULT_DEV_BIN @Args) {
            return
          }
          Write-Host "shell: managed rustc is unavailable right now." -ForegroundColor Yellow
          Write-Host "         For Rust development, use one of these managed entrypoints:" -ForegroundColor Yellow
          Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow
          Write-Host "         - Or add a rust-toolchain.toml file to this directory" -ForegroundColor Yellow
          return 1
        }
        function uv {
          if (Invoke-NucleusManagedDevTool -ToolName "uv" -FallbackBinDirectory $env:NUCLEUS_DEFAULT_DEV_BIN @Args) {
            return
          }
          Write-Host "shell: managed uv is unavailable right now." -ForegroundColor Yellow
          Write-Host "         For Python development, use one of these managed entrypoints:" -ForegroundColor Yellow
          Write-Host "         - Enter a project directory with .envrc (direnv auto-loads the devShell)" -ForegroundColor Yellow
          Write-Host "         - Or use the user-scoped default toolchain installed by nucleus apply" -ForegroundColor Yellow
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
          $gitRoot = git rev-parse --show-toplevel 2>$null
          if ($gitRoot -and (Test-Path (Join-Path $gitRoot "src/flake.nix"))) {
            return $gitRoot
          }
          return $null
        }

        $nucleusSvcCommands = @('list', 'status', 'start', 'stop', 'restart', 'enable', 'disable', 'endpoint', 'logs', 'log-paths', 'log-config')
        $nucleusConfigCommands = @('get', 'set', 'list')

        Register-ArgumentCompleter -CommandName nucleus-svc -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
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
          $nucleusConfigCommands | Where-Object { $_ -like "$wordToComplete*" }
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-gc -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
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
          @('--help', '--min-free-bytes', '--secret-health', '--no-secret-health', '--log-health') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-update -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--flake', '--no-flake', '--brew', '--no-brew', '--sops', '--no-sops') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-check -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--format', '--verify') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-ai-sync -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--dry-run', '--ollama-profile', '--gc-only', '--no-gc-only') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-replica-sync -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--dry-run', '--replica-id', '--repo-root') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-replica-reset -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--dry-run', '--replica-id', '--repo-root') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-bootstrap -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--apply', '--no-apply', '--ai-sync', '--no-ai-sync',
            '--replica-sync', '--no-replica-sync', '--target-user') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-cloud-setup -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--apply', '--no-apply') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-vm-setup -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--dry-run', '--gc', '--no-gc',
            '--mido-patch-file', '--mido-script',
            '--windows-iso', '--no-windows-iso',
            '--windows-iso-source', '--no-windows-iso-source',
            '--windows-iso-retries',
            '--headful', '--no-headful',
            '--vm-dir-override', '--repo-root',
            '--accelerator') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-apply -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--ai-sync', '--no-ai-sync',
            '--replica-sync', '--no-replica-sync',
            '--vm-setup', '--no-vm-setup',
            '--target-user', '--username') |
            Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-bump-lockfile -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help', '--sections', '--verify') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-check-pwsh -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-check-sh -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-service-watchdog -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-gs-pdf-opt -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }

        Register-ArgumentCompleter -CommandName nucleus-test -ScriptBlock {
          param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
          @('--help') | Where-Object { $_ -like "$wordToComplete*" }
        }
  '';
in
{
  # Place the PowerShell profile at the CurrentUserCurrentHost location for
  # interactive pwsh sessions.  On macOS and Linux, pwsh reads this path from
  # $PROFILE.CurrentUserCurrentHost at startup.
  home.file.".config/powershell/Microsoft.PowerShell_profile.ps1".text = profileContent;

  # Install PSScriptAnalyzer for PowerShell linting if pwsh is available.
  # This enables the lint phase in scripts/check-pwsh.ps1.
  home.activation.installPwshScriptAnalyzer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _pwsh="${pkgs.powershell}/bin/pwsh"
    if [ -x "$_pwsh" ] && [ -n "${pwshAnalyzerVersion}" ]; then
      "$_pwsh" -NoProfile -Command "
        \$requiredVersion = '${pwshAnalyzerVersion}'
        \$installed = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
        if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
          if (\$installed) {
            Write-Host 'installPwshScriptAnalyzer: removing PSScriptAnalyzer version '\$(\$installed.Version)'...' -ForegroundColor Yellow
            Uninstall-Module -Name PSScriptAnalyzer -AllVersions -Force
          }
          Write-Host 'installPwshScriptAnalyzer: installing PSScriptAnalyzer version \$requiredVersion...' -ForegroundColor Cyan
          Install-Module -Name PSScriptAnalyzer -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
      "
    fi
  '';

  # Install powershell-yaml for locked DSC validation if pwsh is available.
  # This enables the locked DSC validation phase in scripts/check.ps1.
  home.activation.installPwshYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _pwsh="${pkgs.powershell}/bin/pwsh"
    if [ -x "$_pwsh" ] && [ -n "${pwshYamlVersion}" ]; then
      "$_pwsh" -NoProfile -Command "
        \$requiredVersion = '${pwshYamlVersion}'
        \$installed = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
        if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
          if (\$installed) {
            Write-Host 'installPwshYaml: removing powershell-yaml version '\$(\$installed.Version)'...' -ForegroundColor Yellow
            Uninstall-Module -Name powershell-yaml -AllVersions -Force
          }
          Write-Host 'installPwshYaml: installing powershell-yaml version \$requiredVersion...' -ForegroundColor Cyan
          Install-Module -Name powershell-yaml -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
      "
    fi
  '';
}
