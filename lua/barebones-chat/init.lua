local ui = require("barebones-chat.ui")
local network = require("barebones-chat.network")

local M = {}

-- Default configuration
M.config = {
	-- OpenAI-compatible base URL (LiteLLM, llama-swap, Ollama, etc.)
	-- LiteLLM default: http://localhost:4000
	base_url = "http://localhost:4000",

	-- API key sent as Bearer token. LiteLLM accepts any string by default;
	-- set LITELLM_API_KEY env var or put the key directly here.
	api_key = os.getenv("LITELLM_API_KEY") or "anything",

	model = "local/bonsai",

	-- Optional system prompt sent as the first message
	system_prompt = nil,

	-- Pipeline of functions run on the prompt before sending.
	-- Each receives (prompt, buf) and must return the (modified) prompt string.
	hooks = {},

	-- Optional: Transform/filter each streamed chunk before display.
	-- Return nil to drop the chunk entirely.
	chunk_processor = nil,

	-- Define tools natively in Lua for the LLM to call
	tools = {},
}

--- Setup function to initialize the plugin
--- @param opts table User configuration
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("Barebones", function()
		ui.create_buffer()
	end, { desc = "Open Barebones prompt buffer" })
end

--- Tool Execution Engine with Safety Prompt
--- Intercepts tool execution and prompts for confirmation if it modifies state
--- @param tool_name string
--- @param tool_args table
--- @return string result
function M.execute_tool(tool_name, tool_args)
	local tool = M.config.tools[tool_name]
	if not tool then
		local err = "Tool not found: " .. tool_name
		vim.notify(err, vim.log.levels.ERROR)
		return err
	end

	-- Safety confirmation for state-modifying or shell commands
	if tool.modifies_state then
		local msg = string.format(
			"\n[Barebones] LLM wants to run tool '%s'\nArguments: %s\n\nAllow execution? [Y/n]: ",
			tool_name,
			vim.json.encode(tool_args)
		)

		-- Prompt user in the command line
		local confirm = vim.fn.confirm(msg, "&Yes\n&No", 2)
		if confirm ~= 1 then
			vim.notify("Tool execution cancelled by user.", vim.log.levels.INFO)
			return "User denied tool execution."
		end
	end

	-- Execute the tool natively in Lua
	local ok, result = pcall(tool.execute, tool_args)
	if not ok then
		local err = "Tool execution failed: " .. tostring(result)
		vim.notify(err, vim.log.levels.ERROR)
		return err
	end

	return result
end

--- Submits the buffer content to the LLM
function M.submit()
	local content = ui.get_content()
	if content == "" then
		return
	end

	local final_prompt = content
	for _, hook in ipairs(M.config.hooks) do
		final_prompt = hook(final_prompt, ui.buf) or final_prompt
	end

	ui.append_text("\n\n---\n*Waiting...*\n\n")

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
			-- Apply user-configured chunk processor if present
			if M.config.chunk_processor then
				local processed = M.config.chunk_processor(text)
				if processed == nil then
					return
				end -- skip this chunk
				text = processed
			end
			ui.append_text(text)
		end,
		on_tool_call = function(tool_calls)
			for _, tc in ipairs(tool_calls) do
				-- Handle both OpenAI and Anthropic tool call formats
				local func_name = tc.function_name or (tc["function"] and tc["function"].name) or tc.name
				local args_str = tc.arguments or (tc["function"] and tc["function"].arguments) or tc.input

				if func_name and args_str then
					local args = type(args_str) == "string" and vim.json.decode(args_str) or args_str

					ui.append_text(string.format("\n\n> Executing tool: `%s`...\n", func_name))

					local result = M.execute_tool(func_name, args)

					ui.append_text(string.format("> Result: %s\n\n", tostring(result)))

					-- In a full implementation, we would append the tool result to the messages array
					-- and trigger another network request to let the LLM continue.
				end
			end
		end,
		on_error = function(err)
			ui.append_text("\n\n**Error:** " .. tostring(err) .. "\n")
		end,
		on_complete = function()
			ui.append_text("\n\n---\n\n")
		end,
	})
end

-- ============================================================================
-- Default Tools & Utilities
-- ============================================================================

M.utils = {}

--- Helper to grab the current visual selection
--- @return string text, table range {start_row, start_col, end_row, end_col}
function M.utils.get_visual_selection()
	local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
	local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))

	local lines = vim.fn.getline(csrow, cerow)
	if #lines == 0 then
		return "", nil
	end

	-- Adjust for column selection
	lines[#lines] = string.sub(lines[#lines], 1, cecol)
	lines[1] = string.sub(lines[1], cscol)

	return table.concat(lines, "\n"),
		{
			start_row = csrow - 1, -- 0-indexed for API
			start_col = cscol - 1,
			end_row = cerow - 1,
			end_col = cecol,
		}
end

--- Default tool example: Visual Selection Find & Replace
M.default_tools = {
	replace_visual_selection = {
		description = "Replace the user's current visual selection with new text.",
		modifies_state = true, -- Will trigger the [Y/n] safety prompt
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

			-- Mutate the buffer directly
			vim.api.nvim_buf_set_text(
				0, -- current buffer
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
