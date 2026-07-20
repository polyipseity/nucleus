#!/usr/bin/env bash
# Create ~/dev when absent. VS Code workspace trust and editor tooling rely
# on the directory existing on all hosts.
set -euo pipefail

mkdir -p "$HOME/dev"
