# modules/pwsh.nix — PowerShell profile management for POSIX hosts.
#
# Manages ~/.config/powershell/Microsoft.PowerShell_profile.ps1 so that
# cross-host pwsh behavior mirrors the managed block written by
# Sync-NucleusShellProfile on Windows (src/hosts/windows/modules/sync-shellprofile.ps1).
# Keeping both in sync makes PowerShell behavior consistent across all three
# host types when pwsh is invoked on macOS or NixOS.
{ config, lib, pkgs, ... }:
let
  # Profile content mirroring the Windows managed block in shell.ps1.
  # Using a Nix ''...'' string so the file is written verbatim; single
  # dollar signs and PowerShell variables ($line, $cursor, etc.) do not
  # need escaping because Nix only interpolates ${...} (braced) forms.
  profileContent = ''
    # This file is managed by nucleus (src/modules/pwsh.nix).
    # Manual edits will be overwritten on the next `nix run .#apply`.

    # direnv: load per-directory environments defined in .envrc files.
    if (Get-Command direnv -ErrorAction SilentlyContinue) {
      (& direnv hook pwsh) | Out-String | Invoke-Expression
    }

    # PSReadLine: predictive history completion and menu-style tab expansion.
    # Guards with module availability probe so the profile loads on hosts where
    # PSReadLine is absent or an unexpected version is installed.
    if (Get-Module -ListAvailable -Name PSReadLine) {
      Import-Module PSReadLine
      Set-PSReadLineOption -PredictionSource History
      Set-PSReadLineOption -PredictionViewStyle ListView
      Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    }

    # zoxide: smart directory navigation learned from visit history.
    if (Get-Command zoxide -ErrorAction SilentlyContinue) {
      Invoke-Expression (& zoxide init powershell | Out-String)
    }

    # prek: install repository-local Git hooks automatically the first time a
    # shell session enters a repo that opted into prek via prek.toml.
    # The per-session cache avoids repeated installs on every prompt while
    # still fixing freshly cloned repos as soon as pwsh enters them.
    $global:__nucleusPrekCheckedRepos = @{}
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
      $repoRoot = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null).Trim()
      if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        return
      }

      $prekConfigPath = Join-Path $repoRoot "prek.toml"
      if (-not (Test-Path -Path $prekConfigPath -PathType Leaf)) {
        return
      }
      if ($global:__nucleusPrekCheckedRepos.ContainsKey($repoRoot)) {
        return
      }

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

    function g { & git @Args }
    function ga { & git add @Args }
    function gc { & git commit @Args }
    function gca { & git commit --amend @Args }
    function gco { & git checkout @Args }
    function gd { & git diff @Args }
    function gl { & git log --oneline --decorate --graph @Args }
    function gp { & git push @Args }
    function gpl { & git pull @Args }
    function gs { & git status -sb @Args }
    function gst { & git status @Args }

    # la/ll: prefer eza for colour, icons, and extended metadata; fall back to
    # Get-ChildItem when eza is absent so the profile loads on unmanaged machines.
    if (Get-Command eza -ErrorAction SilentlyContinue) {
      function la { & eza -la @Args }
      function ll { & eza -la @Args }
    } else {
      function la { Get-ChildItem -Force @Args }
      function ll { Get-ChildItem -Force @Args }
    }

    function v { & nvim @Args }

    # System-wide Python ban: redirect python/pip to warnings so users are
    # guided to scoped alternatives instead of modifying the system environment.
    function python {
      Write-Host "shell: system-wide Python is banned to prevent accidental modifications." -ForegroundColor Yellow
      Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow
      Write-Host "         - nix develop     (activate project devShell with scoped Python)" -ForegroundColor Yellow
      Write-Host "         - uv run <cmd>    (run Python via uv package manager)" -ForegroundColor Yellow
      Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow
      Write-Host "         - ./venv/bin/python (use pre-existing project venv)" -ForegroundColor Yellow
      return 1
    }
    function python3 {
      python @Args
    }
    function pip {
      Write-Host "shell: system-wide pip is banned to prevent breaking system dependencies." -ForegroundColor Yellow
      Write-Host "         Use one of these approaches instead:" -ForegroundColor Yellow
      Write-Host "         - nix develop     (activate project devShell with scoped Python+pip)" -ForegroundColor Yellow
      Write-Host "         - uv pip install  (use uv to manage project dependencies)" -ForegroundColor Yellow
      Write-Host "         - uv venv         (create per-project venv managed by uv)" -ForegroundColor Yellow
      Write-Host "         - ./venv/bin/pip  (use pre-existing project venv)" -ForegroundColor Yellow
      return 1
    }
    function pip3 {
      pip @Args
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
    if [ -x "$_pwsh" ]; then
      "$_pwsh" -NoProfile -Command "
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
          Write-Host 'installPwshScriptAnalyzer: installing PSScriptAnalyzer...' -ForegroundColor Cyan
          Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
      "
    fi
  '';
}
