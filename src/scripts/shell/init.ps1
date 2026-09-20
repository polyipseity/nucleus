# This file is managed by nucleus (src/modules/pwsh.nix).
# Manual edits will be overwritten on the next `nix run .#apply`.


# Managed PATH: prepend dirs (before system default).
__MANAGED_PREPEND_PATH__

# Managed PATH: append dirs (after system default).
# Canonical source: env/catalog.json -> managed-paths.nix (pathComponents).
__MANAGED_APPEND_PATH__


# LLVM/Clang toolchain defaults sourced from the centralized env var
# catalog.  All-process on all hosts.
# Source: src/modules/lib/env-secrets.nix (CC, CXX, LD entries).
$env:CC = "__ENV_CC__"
$env:CXX = "__ENV_CXX__"
$env:LD = "__ENV_LD__"

# Managed default dev tools path for profile functions.
$script:NUCLEUS_DEFAULT_DEV_TOOLS = "__DEFAULT_DEV_TOOLS_PATH__"

# ---------------------------------------------------------------
# AI agent session detection
# ---------------------------------------------------------------
# Environment variable names sourced from src/modules/shell/agent-env-vars.nix.
function Test-NucleusAgentSession {
    foreach ($__v in "__AGENT_ENV_VAR_NAMES__" -split ' ') {
        if ($__v -and (Test-Path "env:$__v")) { return $true }
    }
    if (Test-Path "__AGENT_DEVIN_POSIX_PATH__") { return $true }
    return $false
}

# ---------------------------------------------------------------
# SSH agent (gpg-agent)
# ---------------------------------------------------------------
# nix-darwin exports the gpg-agent SSH socket for POSIX shells only, from its
# shell snippet in /etc/zshenv; PowerShell sources no such file, so the socket
# is exported here too.  The token is empty on hosts whose agent comes from the
# session environment (NixOS ssh-agent) or that manage no agent at all, which
# leaves this block inert there.
$_nucleusSshAuthSock = "__ENV_SSH_AUTH_SOCK__"
$_nucleusTty = ""
if ($_nucleusSshAuthSock) {
    $env:SSH_AUTH_SOCK = $_nucleusSshAuthSock
    # GPG_TTY: pinentry needs the controlling terminal of this shell.  `tty`
    # prints "not a tty" and exits non-zero when no terminal is attached, so the
    # exit code is the guard rather than the text.
    $_nucleusTty = & "__SSH_AGENT_TTY_BIN__"
    if ($LASTEXITCODE -eq 0 -and $_nucleusTty) {
        $env:GPG_TTY = $_nucleusTty
        # Point the running agent at this terminal, mirroring what nix-darwin's
        # shell snippet does for the POSIX shells.
        & "__GPG_CONNECT_AGENT_BIN__" --quiet updatestartuptty /bye > $null
    }
}
Remove-Variable -Name _nucleusSshAuthSock, _nucleusTty
