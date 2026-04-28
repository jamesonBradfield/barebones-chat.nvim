local M = {}

M.response_win = nil ---@type integer?
M.response_buf = nil ---@type integer?
M.input_win = nil    ---@type integer?
M.input_buf = nil    ---@type integer?

local _spinner_timer = nil ---@type uv.uv_timer_t?
local _augroup = nil       ---@type integer?

local function is_open()
  return M.response_win and vim.api.nvim_win_is_valid(M.response_win)
end

local function close()
  M.stop_thinking()
  if _augroup then
    -- delete first so WinClosed doesn't re-enter
    vim.api.nvim_del_augroup_by_id(_augroup)
    _augroup = nil
  end
  for _, win in ipairs({ M.response_win, M.input_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, buf in ipairs({ M.response_buf, M.input_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.response_win = nil
  M.response_buf = nil
  M.input_win = nil
  M.input_buf = nil
end

function M.start_thinking()
  if _spinner_timer then return end
  _spinner_timer = vim.uv.new_timer()
  _spinner_timer:start(0, 80, vim.schedule_wrap(function()
    if not is_open() then M.stop_thinking(); return end
    vim.wo[M.response_win].winbar = require("snacks").util.spinner() .. " generating"
  end))
end

function M.stop_thinking()
  if _spinner_timer then
    _spinner_timer:stop()
    _spinner_timer:close()
    _spinner_timer = nil
  end
  if is_open() then
    vim.wo[M.response_win].winbar = ""
  end
end

--- Opens the chat vsplit. Focuses input pane if already open.
--- @param on_submit function(content: string, buf: number)
function M.create_buffer(on_submit)
  if is_open() then
    if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
      vim.api.nvim_set_current_win(M.input_win)
      vim.cmd("startinsert")
    end
    return
  end

  M.response_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.response_buf].filetype = "markdown"

  M.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.input_buf].filetype = "markdown"

  vim.cmd("botright vsplit")
  M.response_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.response_win, M.response_buf)
  vim.api.nvim_win_set_width(M.response_win, math.floor(vim.o.columns * 0.4))

  local rwo = vim.wo[M.response_win]
  rwo.wrap = true
  rwo.conceallevel = 2
  rwo.concealcursor = "nvic"
  rwo.number = false
  rwo.relativenumber = false
  rwo.signcolumn = "no"
  rwo.statuscolumn = ""
  rwo.winfixwidth = true
  rwo.winbar = ""

  vim.cmd("belowright split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_height(M.input_win, 5)

  local iwo = vim.wo[M.input_win]
  iwo.wrap = true
  iwo.number = false
  iwo.relativenumber = false
  iwo.signcolumn = "no"
  iwo.statuscolumn = ""
  iwo.winfixheight = true

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
    local content = vim.trim(table.concat(lines, "\n"))
    if content ~= "" then
      vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
      on_submit(content, M.input_buf)
    end
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = M.input_buf, nowait = true })
  vim.keymap.set("i", "<CR>", submit, { buffer = M.input_buf, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = M.input_buf, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = M.response_buf, nowait = true })

  _augroup = vim.api.nvim_create_augroup("BarebonesChat", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = _augroup,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == M.response_win or closed == M.input_win then
        close()
      end
    end,
  })

  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert")
end

--- Appends streamed text to the response buffer.
--- @param text string
function M.append_text(text)
  vim.schedule(function()
    if not M.response_buf or not vim.api.nvim_buf_is_valid(M.response_buf) then return end

    local lines = vim.split(text, "\n", { plain = true })
    local line_count = vim.api.nvim_buf_line_count(M.response_buf)
    local last_line = vim.api.nvim_buf_get_lines(M.response_buf, line_count - 1, line_count, false)[1] or ""

    lines[1] = last_line .. lines[1]
    vim.api.nvim_buf_set_lines(M.response_buf, line_count - 1, line_count, false, lines)

    if is_open() then
      vim.api.nvim_win_set_cursor(M.response_win, { vim.api.nvim_buf_line_count(M.response_buf), 0 })
    end
  end)
end

--- Safety confirmation for state-modifying tools.
--- @param tool_name string
--- @param tool_args table
--- @return boolean
function M.confirm_tool(tool_name, tool_args)
  local msg = string.format(
    "\n[Barebones] LLM wants to run tool '%s'\nArguments: %s\n\nAllow execution? [Y/n]: ",
    tool_name,
    vim.json.encode(tool_args)
  )
  return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

return M
