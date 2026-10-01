<#
.SYNOPSIS
  Converges managed VS Code extension parity for stable and insiders.

.DESCRIPTION
  Converges a managed extension baseline across stable and insiders channels
  without touching unmanaged extension installs.

.NOTES
  Environment variables: USERPROFILE
#>

function Sync-VSCodeExtensionManifest {
  <#
  .SYNOPSIS
    Converges managed VS Code extension parity for stable and insiders.

  .DESCRIPTION
    Installs or removes the managed set on both the `code` and `code-insiders`
    CLIs. A missing CLI is a warning so bootstrap can proceed before the first
    app launch settles PATH.

    Individual failures are warnings and do not abort the sync, so one
    unavailable extension cannot break convergence of the whole baseline.

  .PARAMETER Enabled
    Install managed extensions when true, remove them when false.
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # Derive repo root from script location (src/platforms/Windows/modules/editors/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $vscodeVersions = if ($lockfile -and $lockfile.suggestions -and $lockfile.suggestions.vscode) { $lockfile.suggestions.vscode } else { @{} }

  $managedExtensions = @(
    'asvetliakov.vscode-neovim',
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
    'ms-ceintl.vscode-language-pack-zh-hant',
    'ms-python.debugpy',
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
    # check-suppress:suppression_doc: probe whether the VS Code CLI is installed; Get-Command throws when absent.
    $cliPath = Get-Command -Name $channel.Command -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source  # check-suppress:suppression_doc: probe -- CLI may not be in PATH; null check below handles absence
    if ([string]::IsNullOrWhiteSpace($cliPath)) {
      Write-NucleusInfo -CommandName 'vscode-extensions' "Skipping VS Code $($channel.Name) extension sync: '$($channel.Command)' not found in PATH."
      continue
    }

    foreach ($extensionId in $managedExtensions) {
      if ($Enabled) {
        $version = $vscodeVersions.$extensionId
        $installSpec = if ($version) { "${extensionId}@${version}" } else { $extensionId }
        # WHY: tinymist gets stable only, because its pre-release builds have caused
        # editor crashes. Every other extension uses --pre-release, and VS Code
        # falls back to stable when a pre-release channel does not exist.
        if ($extensionId -eq 'myriad-dreamin.tinymist') {
          $output = & $cliPath --install-extension $installSpec --force 2>&1
        } else {
          $output = & $cliPath --install-extension $installSpec --pre-release --force 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
          Write-NucleusError -CommandName 'vscode-extensions' "VS Code extension install failed: $extensionId (exit $LASTEXITCODE) — $output"
          throw
        }
      } else {
        $output = & $cliPath --uninstall-extension $extensionId 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-NucleusError -CommandName 'vscode-extensions' "VS Code extension uninstall failed: $extensionId (exit $LASTEXITCODE) — $output"
          throw
        }
      }
    }

    if ($Enabled -and (Test-Path $channel.ExtDir)) {
      # Folders are named publisher.name-version, so match managed IDs (publisher.name)
      # with a prefix check and drop those whose embedded version misses the pin.
      Get-ChildItem -Path $channel.ExtDir -Directory | ForEach-Object {
        $folderName = $_.Name
        $matchedId = $managedExtensions | Where-Object { $folderName -like "$_-*" -or $folderName -eq $_ } | Select-Object -First 1
        if (-not $matchedId) {
          Remove-Item -Path $_.FullName -Recurse -Force
          Write-NucleusInfo -CommandName 'vscode-extensions' "pruned non-managed folder: $folderName ($($channel.Name))"
        } elseif ($vscodeVersions.$matchedId -and $folderName -ne $matchedId) {
          $lastDash = $folderName.LastIndexOf('-')
          if ($lastDash -gt 0) {
            $versionFromFolder = $folderName.Substring($lastDash + 1)
            if ($versionFromFolder -ne ($vscodeVersions.$matchedId -as [string])) {
              Remove-Item -Path $_.FullName -Recurse -Force
              Write-NucleusInfo -CommandName 'vscode-extensions' "pruned stale version folder: $folderName ($($channel.Name))"
            }
          }
        }
      }

      # WHY: extensions.json is a derived manifest VS Code writes on startup, and a
      # stale one hides newly added managed extensions on the next launch.
      # check-suppress:suppression_doc: file may not exist before first VS Code launch; best-effort cleanup.
      Remove-Item -Path (Join-Path $channel.ExtDir 'extensions.json') -Force -ErrorAction Ignore

      # WHY: .obsolete is VS Code's deferred-deletion marker; removing it lets the bridge
      # fully own the directory state.
      Remove-Item -Path (Join-Path $channel.ExtDir '.obsolete') -Force -ErrorAction Ignore
    }
  }
}
