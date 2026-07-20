# Create ~/dev when absent so NixOS mirrors the macOS configureSystemHardening
# behaviour.  VS Code workspace trust and editor tooling rely on the directory
# existing on all hosts.
if [ ! -d "$HOME/dev" ]; then
  mkdir -p "$HOME/dev"
fi
