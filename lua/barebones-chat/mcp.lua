--- Minimal MCP stdio client.
--- Spawns an MCP server subprocess, initializes it, discovers its tools,
--- and provides synchronous tool calls via vim.wait().
local M = {}

M.tools = {} ---@type table<string, {client: table, definition: table}>

--- Connect to an MCP server subprocess.
--- @param cmd table     argv for the server process
--- @param on_ready function(client, tools: table)  called once tools are listed
--- @return table|nil client
function M.connect(cmd, on_ready)
  local client = {
    job_id = nil,
    pending = {},  -- id -> callback
    _req_id = 0,
  }

  local _buf = ""

  local function handle_msg(msg)
    if not msg.id then return end
    local cb = client.pending[msg.id]
    if cb then
      client.pending[msg.id] = nil
      cb(msg.result, msg.error)
    end
  end

  function client:send(method, params, cb)
    self._req_id = self._req_id + 1
    local id = self._req_id
    self.pending[id] = cb
    local line = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() }) .. "\n"
    vim.fn.chansend(self.job_id, line)
  end

  function client:notify(method, params)
    local line = vim.json.encode({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() }) .. "\n"
    vim.fn.chansend(self.job_id, line)
  end

  client.job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, lines)
      for _, chunk in ipairs(lines) do
        chunk = chunk:gsub('\r$', '')
        -- accumulate until we have parseable JSON
        _buf = _buf .. chunk
        local ok, msg = pcall(vim.json.decode, _buf)
        if ok and msg then
          _buf = ""
          handle_msg(msg)
        elseif chunk == "" then
          -- blank line resets partial buffer that won't parse
          _buf = ""
        end
      end
    end,
    on_stderr = function() end, -- servers log to stderr; ignore
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify("[barebones-mcp] server exited with code " .. code, vim.log.levels.WARN)
      end
    end,
  })

  if client.job_id <= 0 then
    vim.notify("[barebones-mcp] failed to start: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
    return nil
  end

  -- Handshake
  client:send("initialize", {
    protocolVersion = "2024-11-05",
    capabilities = vim.empty_dict(),
    clientInfo = { name = "barebones-chat", version = "0.1.0" },
  }, function(_, err)
    if err then
      vim.notify("[barebones-mcp] init error: " .. vim.json.encode(err), vim.log.levels.ERROR)
      return
    end
    client:notify("notifications/initialized")
    client:send("tools/list", vim.empty_dict(), function(result)
      if on_ready then
        on_ready(client, (result or {}).tools or {})
      end
    end)
  end)

  return client
end

--- Call an MCP tool synchronously (blocks via vim.wait up to `timeout` ms).
--- @param client table
--- @param name string
--- @param args table
--- @param timeout? integer  default 15000
--- @return string result
function M.call_tool_sync(client, name, args, timeout)
  local result, done = nil, false

  client:send("tools/call", { name = name, arguments = args }, function(res, err)
    if err then
      result = "MCP error: " .. vim.json.encode(err)
    elseif res and res.content then
      local parts = {}
      for _, item in ipairs(res.content) do
        if item.type == "text" then table.insert(parts, item.text) end
      end
      result = table.concat(parts, "\n")
    else
      result = vim.json.encode(res)
    end
    done = true
  end)

  vim.wait(timeout or 15000, function() return done end, 10)
  return result or "MCP call timed out"
end

return M
