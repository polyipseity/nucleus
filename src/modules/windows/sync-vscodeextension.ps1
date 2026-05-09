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
    Whether managed extension parity should be enforced. False removes the
    managed extensions from discovered VS Code channels.

  .EXAMPLE
    Sync-VSCodeExtensions -Enabled:$true

  .EXAMPLE
    Sync-VSCodeExtensions -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
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
    @{ Name = 'stable'; Command = 'code' },
    @{ Name = 'insiders'; Command = 'code-insiders' }
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
  }
}
