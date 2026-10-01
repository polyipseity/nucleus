# This file is managed by nucleus (src/modules/pwsh.nix).
# Manual edits will be overwritten on the next `nix run .#apply`.


# Managed PATH: prepend dirs (before system default).
__MANAGED_PREPEND_PATH__

# Managed PATH: append dirs (after system default).
# Canonical source: managed-paths.nix (pathComponents).
__MANAGED_APPEND_PATH__


# LLVM/Clang toolchain defaults from the centralized env var catalog.
# Source: src/modules/lib/env-secrets.nix (CC, CXX, LD entries).
$env:CC = "__ENV_CC__"
$env:CXX = "__ENV_CXX__"
$env:LD = "__ENV_LD__"

# Managed default dev tools path for profile functions.
$script:NUCLEUS_DEFAULT_DEV_TOOLS = "__DEFAULT_DEV_TOOLS_PATH__"

# AI agent session detection. Env var names from src/modules/shell/agent-env-vars.nix.
function Test-NucleusAgentSession {
    foreach ($__v in "__AGENT_ENV_VAR_NAMES__" -split ' ') {
        if ($__v -and (Test-Path "env:$__v")) { return $true }
    }
    if (Test-Path "__AGENT_DEVIN_POSIX_PATH__") { return $true }
    return $false
}

# SSH agent (gpg-agent)
#
# nix-darwin exports the gpg-agent SSH socket for POSIX shells from /etc/zshenv
# only, so PowerShell needs it here too. The token is empty on hosts that take
# the socket from the session environment, leaving this block inert.
$_nucleusSshAuthSock = "__ENV_SSH_AUTH_SOCK__"
$_nucleusTty = ""
if ($_nucleusSshAuthSock) {
    $env:SSH_AUTH_SOCK = $_nucleusSshAuthSock
    # GPG_TTY: pinentry needs this shell's terminal. `tty` exits non-zero with
    # no terminal attached, so the exit code is the guard, not the text.
    $_nucleusTty = & "__SSH_AGENT_TTY_BIN__"
    if ($LASTEXITCODE -eq 0 -and $_nucleusTty) {
        $env:GPG_TTY = $_nucleusTty
        & "__GPG_CONNECT_AGENT_BIN__" --quiet updatestartuptty /bye > $null
    }
}
Remove-Variable -Name _nucleusSshAuthSock, _nucleusTty
