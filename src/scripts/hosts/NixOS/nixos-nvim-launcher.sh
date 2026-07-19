# Creates a deterministic symlink at /etc/nucleus-bin/nvim that
# vscode-neovim can use (the extension does not expand ${userHome} or ~).
# Resolves the nvim path from the home-manager profile directory so that no
# username is hardcoded, matching Home Manager's useUserPackages = true layout.
_nvim_path='__NUCLEUS_NVIM_PATH__'
if [ -n "$_nvim_path" ] && [ -x "$_nvim_path" ]; then
  mkdir -p /etc/nucleus-bin
  ln -sfn "$_nvim_path" /etc/nucleus-bin/nvim
fi
