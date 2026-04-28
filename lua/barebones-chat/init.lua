local core = require("barebones-chat.core")
local buffer_ui = require("barebones-chat.ui.buffer")

local M = {}

--- @param opts table
function M.setup(opts)
	core.setup(opts)

	local function on_submit(content, buf)
		if content == "" then return end

		buffer_ui.append_text("\n\n---\n*Waiting...*\n\n")

		core.submit_prompt(content, buf, {
			on_chunk = function(text) buffer_ui.append_text(text) end,
			on_error = function(err) buffer_ui.append_text("\n\n**Error:** " .. tostring(err) .. "\n") end,
			on_complete = function() buffer_ui.append_text("\n\n---\n\n") end,
			confirm_tool = buffer_ui.confirm_tool,
			on_tool_start = function(name) buffer_ui.append_text(string.format("\n\n> Executing tool: `%s`...\n", name)) end,
			on_tool_result = function(_, result) buffer_ui.append_text(string.format("> Result: %s\n\n", tostring(result))) end,
		})
	end

	vim.api.nvim_create_user_command("Barebones", function()
		buffer_ui.create_buffer(on_submit)
	end, { desc = "Open Barebones prompt buffer" })
end

-- Re-export core's public API
M.config = core.config
M.utils = core.utils
M.default_tools = core.default_tools
M.execute_tool = function(...) return core.execute_tool(...) end

return M
