-- lualine extension for the conductor chat input window. Enable it with
--   require('lualine').setup { extensions = { 'conductor_input' } }
-- Shows the session's model, thinking level and context usage, plus status.

---@param text string
---@return string
local function escape(text)
  return (text:gsub('%%', '%%%%'))
end

local function statusline()
  return require 'conductor.statusline'
end

local function name()
  return escape(statusline().name())
end

local function details()
  return escape(statusline().details_text())
end

local function status()
  return escape(statusline().status())
end

local sections = {
  lualine_a = { 'mode' },
  lualine_b = { name },
  lualine_c = { details },
  lualine_x = {},
  lualine_y = {},
  lualine_z = { status },
}

return {
  sections = sections,
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = { name, details },
    lualine_x = { status },
    lualine_y = {},
    lualine_z = {},
  },
  filetypes = { 'conductor_input' },
}
