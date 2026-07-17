# Creates a deterministic symlink at /etc/nucleus-bin/nvim that
# vscode-neovim can use (the extension does not expand ${userHome} or ~).
# Resolves the nvim path from the home-manager profile directory so that no
# username is hardcoded, matching Home Manager's useUserPackages = true layout.
# Expects env var: NUCLEUS_NVIM_PATH
if [ -n "${NUCLEUS_NVIM_PATH:-}" ] && [ -x "$NUCLEUS_NVIM_PATH" ]; then
  mkdir -p /etc/nucleus-bin
  ln -sfn "$NUCLEUS_NVIM_PATH" /etc/nucleus-bin/nvim
fi
