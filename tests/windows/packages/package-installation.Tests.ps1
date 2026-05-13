# tests/windows/packages/package-installation.Tests.ps1 — Pester coverage for
# WinGet-managed package parity on Windows.

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
            Get-Command -Name gitk -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have pwsh available from the PowerShell installation" {
            Get-Command -Name pwsh -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have nvim available from the Neovim installation" {
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
}
