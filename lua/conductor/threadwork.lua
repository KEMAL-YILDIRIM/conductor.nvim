---Runs pure-Lua conductor functions on libuv's threadpool via `vim.uv.new_work`,
---so slow session scans/parses (globbing hundreds of files, reading multi-MB
---JSONL logs) don't block the main thread / UI.
---
---Constraints of the worker context (a fresh Lua state per call, not the
---editor's): only `vim.uv`, `vim.json`, `vim.fs`, and plain Lua stdlib are
---available — no `vim.fn`, `vim.env`, `vim.api`, `vim.g`, upvalues, or
---closures over editor state. Every callee must be requirable by name and
---receive/return only JSON-encodable data.
local M = {}

---Absolute path to the plugin root (parent of `lua/`), resolved once from
---this file's own source path so the worker can rebuild `package.path`
---without any editor API access.
local plugin_root = (function()
  local source = debug.getinfo(1, 'S').source:gsub('^@', '')
  return (vim.fs.normalize(source):gsub('/lua/conductor/threadwork%.lua$', ''))
end)()

---Runs inside the threadpool worker: rebuild package.path, require the
---target module, call the method, and return a JSON envelope (never raises).
---@param root string
---@param module_name string
---@param method_name string dot-separated path into the module table
---@param json_args string JSON-encoded single argument (or JSON null)
---@return string json_envelope { ok: boolean, result?: any, error?: string }
local function worker(root, module_name, method_name, json_args)
  package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

  local mod_ok, mod = pcall(require, module_name)
  if not mod_ok then
    return vim.json.encode { ok = false, error = ('module %q: %s'):format(module_name, tostring(mod)) }
  end

  local fn = mod
  for part in method_name:gmatch '[^.]+' do
    if type(fn) ~= 'table' then
      return vim.json.encode { ok = false, error = ('no such method %q on %q'):format(method_name, module_name) }
    end
    fn = fn[part]
  end
  if type(fn) ~= 'function' then
    return vim.json.encode { ok = false, error = ('no such method %q on %q'):format(method_name, module_name) }
  end

  local decode_ok, args = pcall(vim.json.decode, json_args)
  if not decode_ok then
    return vim.json.encode { ok = false, error = 'bad args: ' .. tostring(args) }
  end
  if args == vim.NIL then
    args = nil
  end

  local call_ok, result = pcall(fn, args)
  if not call_ok then
    return vim.json.encode { ok = false, error = tostring(result) }
  end

  local encode_ok, json_result = pcall(vim.json.encode, { ok = true, result = result })
  if not encode_ok then
    return vim.json.encode { ok = false, error = 'result not JSON-encodable: ' .. tostring(json_result) }
  end
  return json_result
end

---Call `require(module_name)[method_name](args)` on the threadpool and
---deliver the result back on the main loop via `vim.schedule`.
---@param module_name string e.g. 'conductor.adapters.pi'
---@param method_name string e.g. 'list_sessions' or 'fs.delete'
---@param args any|nil single JSON-encodable argument table
---@param callback fun(ok: boolean, result_or_error: any)
function M.call(module_name, method_name, args, callback)
  local work = vim.uv.new_work(worker, function(json_envelope)
    vim.schedule(function()
      local decode_ok, envelope = pcall(vim.json.decode, json_envelope)
      if not decode_ok then
        callback(false, 'threadwork: failed to decode result: ' .. tostring(envelope))
        return
      end
      if envelope.ok then
        callback(true, envelope.result)
      else
        callback(false, envelope.error)
      end
    end)
  end)
  local encode_ok, json_args = pcall(vim.json.encode, args == nil and vim.NIL or args)
  if not encode_ok then
    vim.schedule(function()
      callback(false, 'threadwork: args not JSON-encodable: ' .. tostring(json_args))
    end)
    return
  end
  work:queue(plugin_root, module_name, method_name, json_args)
end

return M
