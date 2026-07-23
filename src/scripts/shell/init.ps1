# This file is managed by nucleus (src/modules/pwsh.nix).
# Manual edits will be overwritten on the next `nix run .#apply`.


# Managed PATH: prepend dirs (before system default).
__MANAGED_PREPEND_PATH__

# Managed PATH: append dirs (after system default).
# Canonical source: env-catalog.nix -> managed-paths.nix (pathComponents).
__MANAGED_APPEND_PATH__


# LLVM/Clang toolchain defaults sourced from the centralized env var
# catalog.  All-process on all hosts.
# Source: src/modules/lib/env-catalog.nix (CC, CXX, LD entries).
$env:CC = "__ENV_CC__"
$env:CXX = "__ENV_CXX__"
$env:LD = "__ENV_LD__"

# Managed default dev tools path for profile functions.
$script:NUCLEUS_DEFAULT_DEV_TOOLS = "__DEFAULT_DEV_TOOLS_PATH__"

# ---------------------------------------------------------------
# AI agent session detection
# ---------------------------------------------------------------
# Environment variable names sourced from src/modules/agent-env-vars.nix.
function Test-NucleusAgentSession {
    foreach ($__v in "__AGENT_ENV_VAR_NAMES__" -split ' ') {
        if ($__v -and (Test-Path "env:$__v")) { return $true }
    }
    if (Test-Path "__AGENT_DEVIN_POSIX_PATH__") { return $true }
    return $false
}
