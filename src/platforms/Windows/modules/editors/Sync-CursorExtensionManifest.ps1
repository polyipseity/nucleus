<#
.SYNOPSIS
  Converges managed Cursor extension parity.

.DESCRIPTION
  Installs or removes a managed extension set on the `cursor` CLI. A missing CLI
  warns and returns so bootstrap proceeds before the first app launch settles PATH.
  Per-extension failures warn without aborting the sync.

.NOTES
  Environment variables: USERPROFILE
  Exit codes: 0 on success; non-zero on failure
#>

function Sync-CursorExtensionManifest {
  <#
  .SYNOPSIS
    Converges managed Cursor extension parity.

  .DESCRIPTION
    Installs or removes a managed extension set on the `cursor` CLI. The managed
    list is the VS Code baseline, so both editors carry the same payload, and the
    version pins come from lockfile.json suggestions.cursor.

  .PARAMETER Enabled
    Mandatory: true installs managed extensions, false removes them.
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # 5 levels up from src/platforms/Windows/modules/editors/ is the repo root.
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $cursorVersions = if ($lockfile -and $lockfile.suggestions -and $lockfile.suggestions.cursor) { $lockfile.suggestions.cursor } else { @{} }

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

  # check-suppress:suppression_doc: probe whether the Cursor CLI is installed; Get-Command throws when absent.
  $cliPath = Get-Command -Name 'cursor' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source  # check-suppress:suppression_doc: probe -- CLI may not be in PATH; null check below handles absence
  if ([string]::IsNullOrWhiteSpace($cliPath)) {
    Write-NucleusInfo -CommandName 'cursor-extensions' "Skipping Cursor extension sync: 'cursor' not found in PATH."
    return
  }

  $extDir = Join-Path $env:USERPROFILE '.cursor\extensions'

  foreach ($extensionId in $managedExtensions) {
    if ($Enabled) {
      $version = $cursorVersions.$extensionId
      $installSpec = if ($version) { "${extensionId}@${version}" } else { $extensionId }
      # tinymist stays on stable: its pre-release builds crash the editor.
      if ($extensionId -eq 'myriad-dreamin.tinymist') {
        $output = & $cliPath --install-extension $installSpec --force 2>&1
      } else {
        $output = & $cliPath --install-extension $installSpec --pre-release --force 2>&1
      }
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning -CommandName 'cursor-extensions' "Cursor extension install failed: $extensionId (exit $LASTEXITCODE) — $output"
      }
    } else {
      $output = & $cliPath --uninstall-extension $extensionId 2>&1
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning -CommandName 'cursor-extensions' "Cursor extension uninstall failed: $extensionId (exit $LASTEXITCODE) — $output"
      }
    }
  }

  if ($Enabled -and (Test-Path $extDir)) {
    # Extension folders are publisher.name-version, so match managed IDs
    # (publisher.name) by prefix, then drop the ones whose version misses the pin.
    Get-ChildItem -Path $extDir -Directory | ForEach-Object {
      $folderName = $_.Name
      $matchedId = $managedExtensions | Where-Object { $folderName -like "$_-*" -or $folderName -eq $_ } | Select-Object -First 1
      if (-not $matchedId) {
        Remove-Item -Path $_.FullName -Recurse -Force
        Write-NucleusInfo -CommandName 'cursor-extensions' "pruned non-managed folder: $folderName"
      } elseif ($cursorVersions.$matchedId -and $folderName -ne $matchedId) {
        $lastDash = $folderName.LastIndexOf('-')
        if ($lastDash -gt 0) {
          $versionFromFolder = $folderName.Substring($lastDash + 1)
          if ($versionFromFolder -ne ($cursorVersions.$matchedId -as [string])) {
            Remove-Item -Path $_.FullName -Recurse -Force
            Write-NucleusInfo -CommandName 'cursor-extensions' "pruned stale version folder: $folderName"
          }
        }
      }
    }

    # Cursor rewrites this manifest on startup, and a stale one hides newly added
    # managed extensions until then. Removing it forces a rescan.
    # check-suppress:suppression_doc: file may not exist before first Cursor launch; best-effort cleanup.
    Remove-Item -Path (Join-Path $extDir 'extensions.json') -Force -ErrorAction Ignore

    # Cursor's deferred-deletion marker; remove it so the bridge owns directory state.
    # WHY: file may not exist; best-effort cleanup.
    Remove-Item -Path (Join-Path $extDir '.obsolete') -Force -ErrorAction Ignore
  }
}
