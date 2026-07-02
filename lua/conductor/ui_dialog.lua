---Presents blocking extension_ui_request dialogs (select/confirm/input/editor)
---via vim.ui.select / vim.ui.input, and sends the response back to the agent.
local M = {}

---@param instance ConductorInstance
---@param payload table response fields (id is added here)
local function respond(instance, payload)
  if not instance.handle or not instance.pending_ui then
    return
  end
  payload.id = instance.pending_ui.id
  instance.pending_ui = nil
  instance.handle.respond_ui(payload)
  -- Status returns to streaming; the agent continues after the response.
  instance.status = 'streaming'
  vim.api.nvim_exec_autocmds('User', { pattern = 'ConductorUpdate', modeline = false })
end

---Show the pending ui_request for an instance.
---@param instance ConductorInstance
function M.show(instance)
  local request = instance.pending_ui
  if not request then
    return
  end
  local title = ('[%s] %s'):format(instance.name, request.title or 'Agent request')

  if request.method == 'select' then
    vim.ui.select(request.options or {}, { prompt = title }, function(choice)
      if choice ~= nil then
        respond(instance, { value = choice })
      else
        respond(instance, { cancelled = true })
      end
    end)
  elseif request.method == 'confirm' then
    local message = request.message and (title .. '\n' .. request.message) or title
    vim.ui.select({ 'Yes', 'No' }, { prompt = message }, function(choice)
      if choice == 'Yes' then
        respond(instance, { confirmed = true })
      elseif choice == 'No' then
        respond(instance, { confirmed = false })
      else
        respond(instance, { cancelled = true })
      end
    end)
  elseif request.method == 'input' or request.method == 'editor' then
    vim.ui.input({ prompt = title .. ' ', default = request.prefill }, function(text)
      if text ~= nil then
        respond(instance, { value = text })
      else
        respond(instance, { cancelled = true })
      end
    end)
  else
    respond(instance, { cancelled = true })
  end
end

return M
