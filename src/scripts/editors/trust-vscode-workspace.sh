# VS Code workspace trust injector.
# Inserts a workspace trust entry for ~/dev into VS Code's SQLite state DB.
# Variables below are substituted via Nix replaceStrings at build time.
set -eu
__PYTHON3_BIN__/bin/python3 '__VSCODE_WORKSPACE_TRUST_PY__'
