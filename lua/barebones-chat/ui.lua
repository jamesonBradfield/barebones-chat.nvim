local M = {}

M.buf = nil
M.win = nil

--- Creates or focuses the prompt buffer in a vertical split
function M.create_buffer()
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            vim.api.nvim_set_current_win(M.win)
            return M.buf, M.win
        end
    end

    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "Barebones")

    vim.api.nvim_set_option_value("filetype", "markdown", { buf = M.buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = M.buf })

    vim.cmd("vsplit")
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.win, M.buf)

    vim.api.nvim_set_option_value("wrap", true, { win = M.win })

    vim.keymap.set("n", "<CR>", function()
        require("barebones-chat").submit()
    end, { buffer = M.buf, desc = "Submit prompt to LLM" })

    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { "# Barebones", "", "> Type your prompt here and press <CR> in normal mode to submit.", "", "---", "" })

    return M.buf, M.win
end

--- Appends text to the chat buffer asynchronously (non-blocking)
--- @param text string The text chunk to append
function M.append_text(text)
    vim.schedule(function()
        if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
        
        local lines = vim.split(text, "\n", { plain = true })
        local line_count = vim.api.nvim_buf_line_count(M.buf)
        
        -- Get the last line to append to it
        local last_line = vim.api.nvim_buf_get_lines(M.buf, line_count - 1, line_count, false)[1] or ""
        
        -- Append first new line to the last existing line
        lines[1] = last_line .. lines[1]
        
        -- Replace the last line and append the rest
        vim.api.nvim_buf_set_lines(M.buf, line_count - 1, line_count, false, lines)
        
        -- Scroll to bottom if window is valid
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            local new_line_count = vim.api.nvim_buf_line_count(M.buf)
            vim.api.nvim_win_set_cursor(M.win, {new_line_count, 0})
        end
    end)
end

--- Gets the full content of the chat buffer
--- @return string
function M.get_content()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return "" end
    local lines = vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
    return table.concat(lines, "\n")
end

return M
