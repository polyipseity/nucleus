<#
.SYNOPSIS
    Pester coverage for the managed per-user Git baseline on Windows.
.DESCRIPTION
    Validates managed fetch, pull and push defaults (branch pruning, tag
    retention, fast-forward pull, auto-setup remote, tag-follow) and cross-host
    Git parity defaults. Signing and symlink keys (commit.gpgsign,
    tag.gpgsign, core.symlinks) are asserted at system scope via the
    system.gitconfig include; core.autocrlf and user.useConfigOnly stay
    per-user.
.NOTES
    Environment variables: USERPROFILE (resolved to locate .gitconfig)
    Exit codes: 0 on success; 1 on failure
#>

$script:gitConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath '.gitconfig'

Describe "Windows Git Configuration Parity" {
    Context "Managed fetch, pull and push defaults" {
        It "Should prune remote-tracking branches on fetch" {
            git config --file $script:gitConfigPath --get fetch.prune | Should -Be 'true'
        }

        It "Should not overwrite local tags on fetch" {
            git config --file $script:gitConfigPath --get fetch.pruneTags | Should -Be 'false'
        }

        It "Should fast-forward pull when possible" {
            git config --file $script:gitConfigPath --get pull.ff | Should -Be 'true'
        }

        It "Should merge rather than rebase on pull" {
            git config --file $script:gitConfigPath --get pull.rebase | Should -Be 'false'
        }

        It "Should auto-setup remote on push" {
            git config --file $script:gitConfigPath --get push.autoSetupRemote | Should -Be 'true'
        }

        It "Should push related tags with branch pushes" {
            git config --file $script:gitConfigPath --get push.followTags | Should -Be 'true'
        }
    }

    Context "Git template boilerplate suppression" {
        It "Should set init.templateDir to empty template directory" {
            git config --file $script:gitConfigPath --get init.templateDir | Should -Be '~/.config/git/empty_template'
        }
    }

    Context "System-scope cross-host Git parity defaults" {
        It "Should enable signed commits at system scope" {
            git config --system --get commit.gpgsign | Should -Be 'true'
        }

        It "Should enable signed tags at system scope" {
            git config --system --get tag.gpgsign | Should -Be 'true'
        }

        It "Should keep symlink support enabled at system scope" {
            git config --system --get core.symlinks | Should -Be 'true'
        }

        It "Should NOT duplicate signing/symlink defaults per-user" {
            git config --file $script:gitConfigPath --get commit.gpgsign | Should -BeNullOrEmpty
            git config --file $script:gitConfigPath --get tag.gpgsign | Should -BeNullOrEmpty
            git config --file $script:gitConfigPath --get core.symlinks | Should -BeNullOrEmpty
        }
    }

    Context "Existing cross-host Git parity defaults" {
        It "Should keep core.autocrlf enabled on Windows" {
            git config --file $script:gitConfigPath --get core.autocrlf | Should -Be 'true'
        }

        It "Should require explicit user identity config" {
            git config --file $script:gitConfigPath --get user.useConfigOnly | Should -Be 'true'
        }
    }
}
