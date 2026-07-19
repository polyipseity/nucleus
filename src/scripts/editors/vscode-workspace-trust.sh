# VS Code workspace trust injector.
# Inserts a workspace trust entry for ~/dev into VS Code's SQLite state DB.
# Tokens: __PYTHON3_BIN__, __VSCODE_WORKSPACE_TRUST_PY__ (replaced by Nix replaceStrings).
set -eu
__PYTHON3_BIN__/bin/python3 '__VSCODE_WORKSPACE_TRUST_PY__'
