<#
.SYNOPSIS
    Pester coverage for WinGet-managed package parity on Windows.
.DESCRIPTION
    Validates that all cross-host CLI tools, developer runtimes and editors,
    GUI applications, and additional WinGet packages declared in
    system/packages.dsc.yml are installed via WinGet.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\helpers\WindowsTestHelpers.ps1')
}

Describe "Windows Package Installation" {
    Context "Cross-host CLI tooling" {
        $cliTools = @(
            @{ id = '7zip.7zip'; displayName = '7-Zip' }
            @{ id = 'ajeetdsouza.zoxide'; displayName = 'zoxide' }
            @{ id = 'astral-sh.ruff'; displayName = 'Ruff' }
            @{ id = 'astral-sh.ty'; displayName = 'ty' }
            @{ id = 'astral-sh.uv'; displayName = 'uv' }
            @{ id = 'BurntSushi.ripgrep'; displayName = 'ripgrep' }
            @{ id = 'direnv.direnv'; displayName = 'direnv' }
            @{ id = 'GitHub.cli'; displayName = 'GitHub CLI' }
            @{ id = 'j178.Prek'; displayName = 'prek' }
            @{ id = 'jqlang.jq'; displayName = 'jq' }
            @{ id = 'junegunn.fzf'; displayName = 'fzf' }
            @{ id = 'sharkdp.bat'; displayName = 'bat' }
            @{ id = 'sharkdp.fd'; displayName = 'fd' }
            @{ id = 'ShellCheck.ShellCheck'; displayName = 'ShellCheck' }
            @{ id = 'Typst.Typst'; displayName = 'Typst' }
        )

        foreach ($tool in $cliTools) {
            It "Should have $($tool.displayName) installed" {
                Test-NucleusWingetPackageInstalled -Id $tool.id | Should -Be $true
            }
        }
    }

    Context "Developer runtimes and editors" {
        $devPackages = @(
            @{ id = 'Git.Git'; displayName = 'Git' }
            @{ id = 'Microsoft.PowerShell'; displayName = 'PowerShell' }
            @{ id = 'Microsoft.VisualStudioCode'; displayName = 'VS Code stable' }
            @{ id = 'Microsoft.VisualStudioCode.Insiders'; displayName = 'VS Code Insiders' }
            @{ id = 'Microsoft.WindowsTerminal.Preview'; displayName = 'Windows Terminal Preview' }
            @{ id = 'Neovim.Neovim'; displayName = 'Neovim' }
            @{ id = 'Ollama.Ollama'; displayName = 'Ollama' }
            @{ id = 'Oven-sh.Bun'; displayName = 'Bun' }
            @{ id = 'Rustlang.Rustup'; displayName = 'rustup' }
            @{ id = 'SecretsOPerationS.SOPS'; displayName = 'SOPS' }
        )

        foreach ($tool in $devPackages) {
            It "Should have $($tool.displayName) installed" {
                Test-NucleusWingetPackageInstalled -Id $tool.id | Should -Be $true
            }
        }

        It "Should have gitk available from the Git installation" {
            # undoc-supp: probe — command may not be installed; WHY: Get-Command returns null when command is not found; Should handles absence.
            Get-Command -Name gitk -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have pwsh available from the PowerShell installation" {
            # undoc-supp: probe — command may not be installed; WHY: Get-Command returns null when command is not found; Should handles absence.
            Get-Command -Name pwsh -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have nvim available from the Neovim installation" {
            # undoc-supp: probe — command may not be installed; WHY: Get-Command returns null when command is not found; Should handles absence.
            Get-Command -Name nvim -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "GUI applications and preferred preview channels" {
        $guiApps = @(
            @{ id = 'BlenderFoundation.Blender'; displayName = 'Blender' }
            @{ id = 'Discord.Discord.Canary'; displayName = 'Discord Canary' }
            @{ id = 'Google.Chrome.Canary'; displayName = 'Google Chrome Canary' }
            @{ id = 'IJHack.QtPass'; displayName = 'QtPass' }
            @{ id = 'Obsidian.Obsidian'; displayName = 'Obsidian' }
            @{ id = 'Telegram.TelegramDesktop.Beta'; displayName = 'Telegram Desktop Beta' }
        )

        foreach ($app in $guiApps) {
            It "Should have $($app.displayName) installed" {
                Test-NucleusWingetPackageInstalled -Id $app.id | Should -Be $true
            }
        }
    }

    Context "Additional WinGet IDs declared in system/packages.dsc.yml" {
        # Keep this list synchronized with package IDs declared in
        # src/hosts/Windows/system/packages.dsc.yml so identifier drift is caught by
        # executable tests instead of silently no-oping at apply time.
        $additionalPackages = @(
            @{ id = '9NBDXK71NK08'; displayName = 'WhatsApp Beta (msstore)' }
            @{ id = 'Adobe.SourceSerif4'; displayName = 'Source Serif 4' }
            @{ id = 'ArtifexSoftware.GhostScript'; displayName = 'Ghostscript' }
            @{ id = 'CaddyServer.Caddy'; displayName = 'Caddy' }
            @{ id = 'Clement.bottom'; displayName = 'bottom' }
            @{ id = 'DEVCOM.JetBrainsMonoNerdFont'; displayName = 'JetBrains Mono Nerd Font' }
            @{ id = 'EqualizerAPO.EqualizerAPO'; displayName = 'Equalizer APO' }
            @{ id = 'eza-community.eza'; displayName = 'eza' }
            @{ id = 'GIMP.GIMP'; displayName = 'GIMP' }
            @{ id = 'GnuPG.Gpg4win'; displayName = 'Gpg4win' }
            @{ id = 'Google.Chrome'; displayName = 'Google Chrome stable' }
            @{ id = 'Google.ChromeRemoteDesktopHost'; displayName = 'Chrome Remote Desktop Host' }
            @{ id = 'Google.NotoSans.CJK.SC'; displayName = 'Noto Sans CJK SC' }
            @{ id = 'Google.NotoSans.CJK.TC'; displayName = 'Noto Sans CJK TC' }
            @{ id = 'Google.NotoSerif.CJK.SC'; displayName = 'Noto Serif CJK SC' }
            @{ id = 'Google.NotoSerif.CJK.TC'; displayName = 'Noto Serif CJK TC' }
            @{ id = 'Gyan.FFmpeg'; displayName = 'FFmpeg (Gyan)' }
            @{ id = 'ImageMagick.ImageMagick'; displayName = 'ImageMagick' }
            @{ id = 'Inter.Inter'; displayName = 'Inter' }
            @{ id = 'KDE.Krita'; displayName = 'Krita' }
            @{ id = 'LLVM.LLVM'; displayName = 'LLVM/Clang' }
            @{ id = 'Microsoft.DotNet.Runtime.6'; displayName = '.NET Runtime 6' }
            @{ id = 'Microsoft.PowerToys'; displayName = 'PowerToys' }
            @{ id = 'Parsec.Parsec'; displayName = 'Parsec' }
            @{ id = 'PeterVerbeek.PeaceEqualizerAPO'; displayName = 'Peace Equalizer APO' }
            @{ id = 'Rclone.Rclone'; displayName = 'rclone' }
            @{ id = 'Scoop.Scoop'; displayName = 'Scoop' }
            @{ id = 'SST.opencode'; displayName = 'OpenCode' }
            @{ id = 'TheDocumentFoundation.LibreOffice'; displayName = 'LibreOffice' }
            @{ id = 'VideoLAN.VLC'; displayName = 'VLC' }
            @{ id = 'WinFsp.WinFsp'; displayName = 'WinFsp' }
            @{ id = 'Zoom.Zoom'; displayName = 'Zoom' }
        )

        foreach ($pkg in $additionalPackages) {
            It "Should have $($pkg.displayName) installed" {
                Test-NucleusWingetPackageInstalled -Id $pkg.id | Should -Be $true
            }
        }
    }
}
