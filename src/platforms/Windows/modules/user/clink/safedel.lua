-- Safe-delete Lua filter for Clink (cmd.exe).
-- Intercepts del, erase, rd, rmdir, rm and redirects to rip.exe (graveyard).
local function is_interactive()
  return true
end

clink.onfilterinput(function(text)
  local cmd, rest = text:match("^%s*(%a+)%s*(.*)")
  if cmd then
    local lcmd = cmd:lower()
    if lcmd == "del" or lcmd == "erase" or lcmd == "rd" or lcmd == "rmdir" or lcmd == "rm" then
      if is_interactive() then
        io.write("[SafeDelete] Redirecting to rip. Tip: use rip -u to undo.\n")
      end
      -- Translate Windows slash options (/s, /f, /q, /p) -> drop them
      local clean_args = rest:gsub("/[fFsSqQpP]", "")
      return "rip.exe " .. clean_args
    end
  end
  return text
end)
