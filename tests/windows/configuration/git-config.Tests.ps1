# tests/windows/configuration/git-config.Tests.ps1 — Pester coverage for the
# managed per-user Git baseline on Windows.

$script:gitConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath '.gitconfig'

Describe "Windows Git Configuration Parity" {
    Context "Managed fetch and push defaults" {
        It "Should prune remote-tracking branches on fetch" {
            git config --file $script:gitConfigPath --get fetch.prune | Should -Be 'true'
        }

        It "Should prune tags on fetch" {
            git config --file $script:gitConfigPath --get fetch.pruneTags | Should -Be 'true'
        }

        It "Should push related tags with branch pushes" {
            git config --file $script:gitConfigPath --get push.followTags | Should -Be 'true'
        }
    }

    Context "Existing cross-host Git parity defaults" {
        It "Should enable signed commits" {
            git config --file $script:gitConfigPath --get commit.gpgsign | Should -Be 'true'
        }

        It "Should enable signed tags" {
            git config --file $script:gitConfigPath --get tag.gpgsign | Should -Be 'true'
        }

        It "Should keep core.autocrlf enabled on Windows" {
            git config --file $script:gitConfigPath --get core.autocrlf | Should -Be 'true'
        }

        It "Should keep symlink support enabled" {
            git config --file $script:gitConfigPath --get core.symlinks | Should -Be 'true'
        }

        It "Should require explicit user identity config" {
            git config --file $script:gitConfigPath --get user.useConfigOnly | Should -Be 'true'
        }
    }
}
