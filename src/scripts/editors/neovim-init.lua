-- Managed by Home Manager (nucleus): generated from src/scripts/configs/neovim-init.lua
-- Neovim supports native Lua config in init.lua (or Vimscript init.vim).
-- Keep init.lua as the canonical managed format here.

local managed = {
  enable_shift_number_symbols_workaround = __ENABLE_WORKAROUND__,
  shift_number_terminal_programs = __SHIFT_NUMBER_TERMINAL_PROGRAMS__,
}

if managed.enable_shift_number_symbols_workaround then
  local terminal_program = (vim.env.TERM_PROGRAM or ""):lower()
  local term_value = (vim.env.TERM or ""):lower()
  local kitty_window_id = vim.env.KITTY_WINDOW_ID or ""
  local has_kitty_protocol =
    kitty_window_id ~= "" or term_value:find("kitty", 1, true) ~= nil
  local should_apply = has_kitty_protocol

  for _, candidate in ipairs(managed.shift_number_terminal_programs or {}) do
    if terminal_program == tostring(candidate):lower() then
      should_apply = true
      break
    end
  end

  if should_apply then
    local shifted_digits = {
__SHIFT_NUMBER_TABLE__
    }

    for digit, symbol in pairs(shifted_digits) do
      local shifted_key = "<S-" .. digit .. ">"
      vim.keymap.set({ "i", "n", "x" }, shifted_key, symbol, {
        desc = "workaround: shifted-number terminal protocol regression",
        noremap = true,
        silent = true,
      })
      vim.keymap.set("c", shifted_key, function()
        return symbol
      end, {
        expr = true,
        noremap = true,
      })
    end
  end
end

-- VS Code-specific settings (when running as embedded Neovim in VS Code).
-- <Leader>f calls VS Code's native formatSelection, which respects
-- project-specific formatters (Prettier, rustfmt, etc.) instead of
-- relying on Neovim's formatprg.
if vim.g.vscode then
  vim.keymap.set({ "n", "v" }, "<Leader>f", function()
    require("vscode").call("editor.action.formatSelection")
  end)
end

-- jk -> <Esc> in insert mode for faster escape without leaving home row.
vim.keymap.set("i", "jk", "<Esc>", { noremap = true, silent = true })
