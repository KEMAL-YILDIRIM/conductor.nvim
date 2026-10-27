---blink.cmp source for `/` commands in the chat input bar. Registered at
---runtime by `conductor.completion` (no user config needed); enabled only in
---the `conductor_input` filetype.
local completion = require 'conductor.completion'

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == completion.FILETYPE
end

function source:get_trigger_characters()
  return { '/' }
end

---@type table<string, integer>
local KIND_BY_SOURCE = { builtin = 3, prompt = 15, skill = 9, extension = 2 } -- Function, Snippet, Module, Method

local EMPTY = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

function source:get_completions(context, callback)
  local row, col = context.cursor[1], context.cursor[2]
  if not completion.slash_query(context.line, row, col) then
    callback(EMPTY)
    return
  end
  completion.items(context.bufnr, function(commands)
    local items = {}
    for _, command in ipairs(commands) do
      local text = '/' .. command.name
      items[#items + 1] = {
        label = text,
        -- `/` is not a keyword character: blink fuzzy-matches the bare name.
        filterText = command.name,
        kind = KIND_BY_SOURCE[command.source] or 2,
        labelDetails = { detail = command.args and (' ' .. command.args) or nil, description = command.source },
        documentation = command.description ~= '' and command.description or nil,
        textEdit = {
          newText = text,
          range = { start = { line = row - 1, character = 0 }, ['end'] = { line = row - 1, character = col } },
        },
      }
    end
    callback { is_incomplete_forward = false, is_incomplete_backward = false, items = items }
  end)
end

return source
