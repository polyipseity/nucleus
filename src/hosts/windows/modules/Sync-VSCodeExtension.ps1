# modules/windows/sync-vscodeextension.ps1 — VS Code extension parity helper.
#
# Converges a managed extension baseline across stable and insiders channels
# without touching unmanaged extension installs.

function Sync-VSCodeExtension {
  <#
  .SYNOPSIS
    Converges managed VS Code extension parity for stable and insiders.

  .DESCRIPTION
    Installs or removes a managed extension set on both `code` and
    `code-insiders` CLIs when available. Missing CLIs are treated as a warning
    so bootstrap can proceed before first app launch PATH updates settle.

    Each extension is installed with --pre-release --force so the latest
    pre-release build is fetched; VS Code falls back to stable automatically
    when a pre-release channel does not exist for an extension.
    myriad-dreamin.tinymist is installed without --pre-release because its
    pre-release builds have caused editor crashes on some machines.

    Individual extension failures are reported as warnings but do not abort
    the sync so a single unavailable extension does not break the entire
    baseline convergence.

    Cleanup behavior when disabled removes only managed extensions.

  .PARAMETER Enabled
    Whether managed extension parity should be enforced. Mandatory: caller
    must explicitly choose true (install managed extensions) or false
    (remove managed extensions).

  .EXAMPLE
    Sync-VSCodeExtension -Enabled:$true

  .EXAMPLE
    Sync-VSCodeExtension -Enabled:$false
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $managedExtensions = @(
    'arrterian.nix-env-selector',
    'astral-sh.ty',
    'charliermarsh.ruff',
    'christian-kohler.npm-intellisense',
    'christian-kohler.path-intellisense',
    'cl.eide',
    'cschlosser.doxdocgen',
    'davidanson.vscode-markdownlint',
    'dbaeumer.vscode-eslint',
    'docker.docker',
    'editorconfig.editorconfig',
    'esbenp.prettier-vscode',
    'github.codespaces',
    'github.remotehub',
    'github.vscode-github-actions',
    'heaths.vscode-guid',
    'ibm.output-colorizer',
    'icrawl.discord-vscode',
    'james-yu.latex-workshop',
    'jnoortheen.nix-ide',
    'keroc.hex-fmt',
    'mark-hansen.hledger-vscode',
    'mkhl.direnv',
    'ms-azuretools.vscode-containers',
    'ms-azuretools.vscode-docker',
    'ms-ceintl.vscode-language-pack-zh-hant',
    'ms-python.debugpy',
    'ms-python.isort',
    'ms-python.python',
    'ms-python.vscode-python-envs',
    'ms-toolsai.datawrangler',
    'ms-toolsai.jupyter',
    'ms-toolsai.jupyter-keymap',
    'ms-toolsai.jupyter-renderers',
    'ms-toolsai.vscode-jupyter-cell-tags',
    'ms-toolsai.vscode-jupyter-slideshow',
    'ms-vscode-remote.remote-containers',
    'ms-vscode-remote.remote-ssh',
    'ms-vscode-remote.remote-ssh-edit',
    'ms-vscode-remote.remote-wsl',
    'ms-vscode.cmake-tools',
    'ms-vscode.cpp-devtools',
    'ms-vscode.cpptools',
    'ms-vscode.cpptools-extension-pack',
    'ms-vscode.cpptools-themes',
    'ms-vscode.hexeditor',
    'ms-vscode.makefile-tools',
    'ms-vscode.powershell',
    'ms-vscode.remote-explorer',
    'ms-vscode.remote-repositories',
    'ms-vscode.remote-server',
    'ms-vscode.vscode-chat-customizations-evaluations',
    'ms-vscode.vscode-serial-monitor',
    'ms-vsliveshare.vsliveshare',
    'myriad-dreamin.tinymist',
    'redhat.vscode-yaml',
    'rust-lang.rust-analyzer',
    's-nlf-fh.glassit',
    'sjhuangx.vscode-scheme',
    'sst-dev.opencode-v2',
    'streetsidesoftware.code-spell-checker',
    'svelte.svelte-vscode',
    'takumii.markdowntable',
    'tamasfe.even-better-toml',
    'tweag.vscode-nickel',
    'vadimcn.vscode-lldb'
  )

  $channels = @(
    @{ Name = 'stable';   Command = 'code';          ExtDir = Join-Path $env:USERPROFILE '.vscode\extensions' },
    @{ Name = 'insiders'; Command = 'code-insiders'; ExtDir = Join-Path $env:USERPROFILE '.vscode-insiders\extensions' }
  )

  foreach ($channel in $channels) {
    $cliPath = Get-Command -Name $channel.Command -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($cliPath)) {
      Write-Output "Skipping VS Code $($channel.Name) extension sync: '$($channel.Command)' not found in PATH."
      continue
    }

    foreach ($extensionId in $managedExtensions) {
      if ($Enabled) {
        # tinymist: install stable only — pre-release builds have caused
        # editor crashes.  All other extensions use --pre-release; VS Code
        # falls back to stable when a pre-release channel does not exist.
        if ($extensionId -eq 'myriad-dreamin.tinymist') {
          $output = & $cliPath --install-extension $extensionId --force 2>&1
        } else {
          $output = & $cliPath --install-extension $extensionId --pre-release --force 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
          Write-Warning "vscode-extensions: VS Code extension install failed: $extensionId (exit $LASTEXITCODE) — $output"
        }
      } else {
        $output = & $cliPath --uninstall-extension $extensionId 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Warning "vscode-extensions: VS Code extension uninstall failed: $extensionId (exit $LASTEXITCODE) — $output"
        }
      }
    }

    if ($Enabled -and (Test-Path $channel.ExtDir)) {
      # Prune the extensions directory so the managed baseline is the sole
      # source of truth.  Extension folders are named publisher.name-version;
      # match against managed IDs (publisher.name) using a prefix check.
      Get-ChildItem -Path $channel.ExtDir -Directory | ForEach-Object {
        $folderName = $_.Name
        $isManaged = $managedExtensions | Where-Object { $folderName -like "$_-*" -or $folderName -eq $_ }
        if (-not $isManaged) {
          Remove-Item -Path $_.FullName -Recurse -Force
          Write-Output "vscode-extensions: pruned non-managed folder: $folderName ($($channel.Name))"
        }
      }

      # extensions.json is a derived manifest VS Code writes on startup; a stale
      # one hides newly added managed extensions on the next launch.  Remove it
      # unconditionally so VS Code rescans the directory from the actual contents.
      # Absence is expected when VS Code has not yet been launched — benign.
      Remove-Item -Path (Join-Path $channel.ExtDir 'extensions.json') -Force -ErrorAction SilentlyContinue

      # .obsolete is VS Code's deferred-deletion marker; remove it so the bridge
      # fully owns the directory state.  Absence is expected and benign.
      Remove-Item -Path (Join-Path $channel.ExtDir '.obsolete') -Force -ErrorAction SilentlyContinue
    }
  }
}
