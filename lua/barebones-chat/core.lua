local network = require("barebones-chat.network")

local M = {}

M.config = {
	base_url = "http://localhost:4000",
	api_key = os.getenv("LITELLM_API_KEY") or "anything",
	model = "local/bonsai",
	system_prompt = nil,
	hooks = {},
	chunk_processor = nil,
	tools = {},
}

--- @param opts table
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Execute a registered tool.
--- @param tool_name string
--- @param tool_args table
--- @param confirm_fn function(name, args) -> bool  Called only when tool.modifies_state is true
--- @return string result
function M.execute_tool(tool_name, tool_args, confirm_fn)
	local tool = M.config.tools[tool_name]
	if not tool then
		local err = "Tool not found: " .. tool_name
		vim.notify(err, vim.log.levels.ERROR)
		return err
	end

	if tool.modifies_state and confirm_fn then
		if not confirm_fn(tool_name, tool_args) then
			vim.notify("Tool execution cancelled by user.", vim.log.levels.INFO)
			return "User denied tool execution."
		end
	end

	local ok, result = pcall(tool.execute, tool_args)
	if not ok then
		local err = "Tool execution failed: " .. tostring(result)
		vim.notify(err, vim.log.levels.ERROR)
		return err
	end

	return result
end

--- Submit a prompt to the LLM.
--- @param prompt string
--- @param buf number|nil Source buffer, passed to hooks
--- @param callbacks table {
---   on_chunk(text),
---   on_error(err),
---   on_complete(),
---   confirm_tool(name, args) -> bool,
---   on_tool_start(name, args),
---   on_tool_result(name, result),
--- }
function M.submit_prompt(prompt, buf, callbacks)
	callbacks = callbacks or {}

	local final_prompt = prompt
	for _, hook in ipairs(M.config.hooks) do
		final_prompt = hook(final_prompt, buf) or final_prompt
	end

	local messages = {}
	if M.config.system_prompt then
		table.insert(messages, { role = "system", content = M.config.system_prompt })
	end
	table.insert(messages, { role = "user", content = final_prompt })

	local payload = {
		model = M.config.model,
		messages = messages,
		stream = true,
	}

	local tools_payload = {}
	for name, tool in pairs(M.config.tools) do
		table.insert(tools_payload, {
			type = "function",
			["function"] = {
				name = name,
				description = tool.description or "",
				parameters = tool.parameters or { type = "object", properties = {} },
			},
		})
	end
	if #tools_payload > 0 then
		payload.tools = tools_payload
	end

	local url = M.config.base_url:gsub("/+$", "") .. "/v1/chat/completions"
	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. M.config.api_key,
	}

	network.stream_request(payload, {
		url = url,
		headers = headers,
		on_chunk = function(text)
			if M.config.chunk_processor then
				local processed = M.config.chunk_processor(text)
				if processed == nil then return end
				text = processed
			end
			if callbacks.on_chunk then callbacks.on_chunk(text) end
		end,
		on_tool_call = function(tool_calls)
			for _, tc in ipairs(tool_calls) do
				local func_name = tc.function_name or (tc["function"] and tc["function"].name) or tc.name
				local args_str = tc.arguments or (tc["function"] and tc["function"].arguments) or tc.input

				if func_name and args_str then
					local args = type(args_str) == "string" and vim.json.decode(args_str) or args_str

					if callbacks.on_tool_start then callbacks.on_tool_start(func_name, args) end

					local result = M.execute_tool(func_name, args, callbacks.confirm_tool)

					if callbacks.on_tool_result then callbacks.on_tool_result(func_name, result) end
				end
			end
		end,
		on_error = function(err)
			if callbacks.on_error then callbacks.on_error(err) end
		end,
		on_complete = function()
			if callbacks.on_complete then callbacks.on_complete() end
		end,
	})
end

-- ============================================================================
-- Default Tools & Utilities
-- ============================================================================

M.utils = {}

--- @return string text, table|nil range {start_row, start_col, end_row, end_col}
function M.utils.get_visual_selection()
	local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
	local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))

	local lines = vim.fn.getline(csrow, cerow)
	if #lines == 0 then
		return "", nil
	end

	lines[#lines] = string.sub(lines[#lines], 1, cecol)
	lines[1] = string.sub(lines[1], cscol)

	return table.concat(lines, "\n"),
		{
			start_row = csrow - 1,
			start_col = cscol - 1,
			end_row = cerow - 1,
			end_col = cecol,
		}
end

M.default_tools = {
	replace_visual_selection = {
		description = "Replace the user's current visual selection with new text.",
		modifies_state = true,
		parameters = {
			type = "object",
			properties = {
				replacement_text = {
					type = "string",
					description = "The exact text to replace the visual selection with.",
				},
			},
			required = { "replacement_text" },
		},
		execute = function(args)
			local replacement = args.replacement_text
			if not replacement then
				return "Error: replacement_text missing"
			end

			local _, range = M.utils.get_visual_selection()
			if not range then
				return "Error: No visual selection found."
			end

			local replacement_lines = vim.split(replacement, "\n", { plain = true })

			vim.api.nvim_buf_set_text(
				0,
				range.start_row,
				range.start_col,
				range.end_row,
				range.end_col,
				replacement_lines
			)

			return "Successfully replaced visual selection."
		end,
	},
}

return M
