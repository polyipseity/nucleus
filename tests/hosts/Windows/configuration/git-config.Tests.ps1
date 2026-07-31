<#
.SYNOPSIS
    Pester coverage for the managed per-user Git baseline on Windows.
.DESCRIPTION
    Validates managed fetch, pull and push defaults (branch pruning, tag
    retention, fast-forward pull, auto-setup remote, tag-follow), cross-host
    Git parity defaults (signed commits, signed tags, core.autocrlf,
    core.symlinks, user.useConfigOnly).
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
