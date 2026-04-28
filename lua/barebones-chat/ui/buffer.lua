local Snacks = require("snacks")

local M = {}

M.layout = nil       ---@type snacks.layout?
M.response_win = nil ---@type snacks.win?
M.input_win = nil    ---@type snacks.win?

local _spinner_timer = nil ---@type uv.uv_timer_t?

function M.start_thinking()
  if _spinner_timer then return end
  _spinner_timer = vim.uv.new_timer()
  _spinner_timer:start(0, 80, vim.schedule_wrap(function()
    if not M.layout or not M.layout:valid() then
      M.stop_thinking()
      return
    end
    M.layout.root:set_title(Snacks.util.spinner() .. " generating")
  end))
end

function M.stop_thinking()
  if _spinner_timer then
    _spinner_timer:stop()
    _spinner_timer:close()
    _spinner_timer = nil
  end
  if M.layout and M.layout:valid() then
    M.layout.root:set_title("barebones")
  end
end

--- Opens the chat layout. Focuses input pane if already open.
--- @param on_submit function(content: string, buf: number)
function M.create_buffer(on_submit)
  if M.layout and M.layout:valid() then
    M.input_win:focus()
    vim.cmd("startinsert")
    return
  end

  M.response_win = Snacks.win({
    show = false,
    ft = "markdown",
    bo = { buftype = "nofile", swapfile = false },
    wo = { wrap = true, conceallevel = 2, concealcursor = "nvic" },
  })

  M.input_win = Snacks.win({
    show = false,
    ft = "markdown",
    bo = { buftype = "nofile", swapfile = false },
    wo = { wrap = true },
    keys = {
      q = false,
      ["<CR>"] = function(self)
        local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
        local content = vim.trim(table.concat(lines, "\n"))
        if content ~= "" then
          vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
          on_submit(content, self.buf)
        end
      end,
    },
  })

  local focused = false
  M.layout = Snacks.layout.new({
    wins = { response = M.response_win, input = M.input_win },
    on_update = function()
      if not focused and M.input_win and M.input_win:valid() then
        focused = true
        M.input_win:focus()
        vim.cmd("startinsert")
      end
    end,
    on_close = function()
      M.stop_thinking()
      M.layout = nil
      M.response_win = nil
      M.input_win = nil
    end,
    layout = {
      box = "vertical",
      width = 0.5,
      height = 0.9,
      border = "rounded",
      title = " barebones ",
      title_pos = "center",
      {
        win = "response",
        border = "none",
      },
      {
        win = "input",
        height = 5,
        border = "top",
        title = " prompt · <CR> send · q close ",
        title_pos = "center",
      },
    },
  })
end

--- Appends streamed text to the response buffer.
--- @param text string
function M.append_text(text)
  vim.schedule(function()
    if not M.response_win or not M.response_win:valid() then return end
    local buf = M.response_win.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

    local lines = vim.split(text, "\n", { plain = true })
    local line_count = vim.api.nvim_buf_line_count(buf)
    local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""

    lines[1] = last_line .. lines[1]
    vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, lines)

    local win = M.response_win.win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
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
