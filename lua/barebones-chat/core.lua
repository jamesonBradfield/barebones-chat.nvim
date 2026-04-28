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
	mcp_servers = {},    -- { { name="browser", cmd={"npx","browser-control-mcp"} }, ... }
	telekasten_home = nil, -- vault path; auto-detected from telekasten.nvim if nil
}

--- @param opts table
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	local mcp = require("barebones-chat.mcp")
	for _, srv in ipairs(M.config.mcp_servers) do
		local label = srv.name or table.concat(srv.cmd, " ")
		mcp.connect(srv.cmd, function(client, tools)
			for _, tool in ipairs(tools) do
				mcp.tools[tool.name] = { client = client, definition = tool }
			end
			vim.notify(
				string.format("[barebones] MCP '%s' ready (%d tools)", label, #tools),
				vim.log.levels.INFO
			)
		end)
	end
end

--- Execute a registered tool (local or MCP).
--- @param tool_name string
--- @param tool_args table
--- @param confirm_fn function(name, args) -> bool
--- @return string result
function M.execute_tool(tool_name, tool_args, confirm_fn)
	local tool = M.config.tools[tool_name]

	if not tool then
		-- fall through to MCP
		local mcp = require("barebones-chat.mcp")
		local entry = mcp.tools[tool_name]
		if entry then
			if confirm_fn and not confirm_fn(tool_name, tool_args) then
				return "User denied tool execution."
			end
			return mcp.call_tool_sync(entry.client, tool_name, tool_args)
		end
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

--- Build the API payload for a given message history.
--- @param messages table
--- @return table payload
function M._build_payload(messages)
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

	local mcp = require("barebones-chat.mcp")
	for name, entry in pairs(mcp.tools) do
		table.insert(tools_payload, {
			type = "function",
			["function"] = {
				name = name,
				description = entry.definition.description or "",
				-- MCP uses inputSchema; OpenAI uses parameters
				parameters = entry.definition.inputSchema or { type = "object", properties = {} },
			},
		})
	end

	return {
		model = M.config.model,
		messages = messages,
		stream = true,
		tools = #tools_payload > 0 and tools_payload or nil,
	}
end

--- Internal recursive agentic loop.
--- Calls the LLM, executes any tools, feeds results back, and repeats until
--- the model produces a response with no tool calls (or max depth is hit).
--- @param messages table conversation history
--- @param callbacks table
--- @param depth integer recursion guard (default 0)
function M._do_llm_turn(messages, callbacks, depth)
	depth = depth or 0
	if depth > 10 then
		if callbacks.on_error then callbacks.on_error("Max tool-call depth reached") end
		return
	end

	local url = M.config.base_url:gsub("/+$", "") .. "/v1/chat/completions"
	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. M.config.api_key,
	}

	local assistant_text = ""
	local pending_tool_calls = nil

	network.stream_request(M._build_payload(messages), {
		url = url,
		headers = headers,

		on_chunk = function(text)
			if M.config.chunk_processor then
				local processed = M.config.chunk_processor(text)
				if processed == nil then return end
				text = processed
			end
			assistant_text = assistant_text .. text
			if callbacks.on_chunk then callbacks.on_chunk(text) end
		end,

		-- fired once in on_exit with complete, accumulated tool calls
		on_tool_call = function(tool_calls)
			pending_tool_calls = tool_calls
		end,

		on_error = function(err)
			if callbacks.on_error then callbacks.on_error(err) end
		end,

		-- has_calls = true when on_tool_call was fired
		on_complete = function(has_calls)
			if not has_calls or not pending_tool_calls then
				if callbacks.on_complete then callbacks.on_complete() end
				return
			end

			-- Build the assistant turn with tool_calls embedded
			local assistant_msg = {
				role = "assistant",
				content = assistant_text ~= "" and assistant_text or vim.NIL,
				tool_calls = {},
			}

			local next_messages = vim.deepcopy(messages)
			table.insert(next_messages, assistant_msg)

			for i, tc in ipairs(pending_tool_calls) do
				local tc_id = (tc.id ~= "" and tc.id) or ("call_" .. tc.function_name .. "_" .. i)
				table.insert(assistant_msg.tool_calls, {
					id = tc_id,
					type = "function",
					["function"] = { name = tc.function_name, arguments = tc.arguments },
				})

				local ok, args = pcall(vim.json.decode, tc.arguments)
				args = ok and args or {}

				if callbacks.on_tool_start then callbacks.on_tool_start(tc.function_name, args) end
				local result = M.execute_tool(tc.function_name, args, callbacks.confirm_tool)
				if callbacks.on_tool_result then callbacks.on_tool_result(tc.function_name, result) end

				table.insert(next_messages, {
					role = "tool",
					tool_call_id = tc_id,
					content = tostring(result),
				})
			end

			-- Loop: send tool results back and continue
			M._do_llm_turn(next_messages, callbacks, depth + 1)
		end,
	})
end

--- Submit a prompt to the LLM.
--- @param prompt string
--- @param buf number|nil  source buffer, passed to hooks
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

	M._do_llm_turn(messages, callbacks)
end

-- ============================================================================
-- System Prompts
-- ============================================================================

M.system_prompts = {
	wgu_tutor = [[Role & Objective:
You are an ultra-efficient Objective Assessment Tutor for a WGU student who relies heavily on pattern recognition. Your sole objective is to help the user reverse-engineer test questions to pass exams. You do not teach the underlying theory or the "why" unless explicitly asked. You teach the mechanics of getting the correct answer.

Operational Rules:
When the user provides a question, a concept, or a screenshot of a pre-assessment:

1. The Data Map: Immediately identify the structural pattern of the question. Tell the user exactly which numbers, keywords, or variables to pull from the prompt. Explicitly point out what text is just "fluff" or a distractor.
2. The KISS Procedure: Provide a rigid, step-by-step mechanical process (a mental lookup table) to solve that specific type of problem. Keep it as stripped-down as possible.
3. Zero Fluff Policy: No introductory paragraphs, no concluding summaries, no motivational cheerleading, and absolutely no deep dives into theoretical concepts. Get straight to the data and the procedure.]],
}

-- ============================================================================
-- Default Tools & Utilities
-- ============================================================================

M.utils = {}

--- @return string text, table|nil range {start_row, start_col, end_row, end_col}
function M.utils.get_visual_selection()
	local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
	local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))

	local lines = vim.fn.getline(csrow, cerow)
	if #lines == 0 then return "", nil end

	lines[#lines] = string.sub(lines[#lines], 1, cecol)
	lines[1] = string.sub(lines[1], cscol)

	return table.concat(lines, "\n"), {
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
			if not args.replacement_text then return "Error: replacement_text missing" end
			local _, range = M.utils.get_visual_selection()
			if not range then return "Error: No visual selection found." end
			vim.api.nvim_buf_set_text(
				0,
				range.start_row, range.start_col,
				range.end_row, range.end_col,
				vim.split(args.replacement_text, "\n", { plain = true })
			)
			return "Successfully replaced visual selection."
		end,
	},

	telekasten_create_note = {
		description = "Create a new Telekasten/Obsidian note with a title and markdown body. Use this to save study guides, key procedures, or exam patterns.",
		modifies_state = true,
		parameters = {
			type = "object",
			properties = {
				title   = { type = "string", description = "Note title" },
				content = { type = "string", description = "Note body in markdown" },
				tags    = { type = "array", items = { type = "string" }, description = "Optional list of tags" },
			},
			required = { "title", "content" },
		},
		execute = function(args)
			local home = M.config.telekasten_home
			if not home then
				local ok, tk = pcall(require, "telekasten")
				home = ok and tk.Cfg and tk.Cfg.home
			end
			if not home then
				return "Error: set telekasten_home in setup() or install telekasten.nvim"
			end

			home = vim.fn.expand(home)
			if vim.fn.isdirectory(home) == 0 then
				return "Error: directory does not exist: " .. home
			end

			local safe = args.title:gsub("[/\\:*?\"<>|]", "-"):gsub("%s+", "-")
			local stamp = os.date("%Y%m%d%H%M%S")
			local path = home .. "/" .. stamp .. "-" .. safe .. ".md"

			local front = "---\ntitle: " .. args.title .. "\ndate: " .. os.date("%Y-%m-%d")
			if args.tags and #args.tags > 0 then
				front = front .. "\ntags: [" .. table.concat(args.tags, ", ") .. "]"
			end
			front = front .. "\n---\n\n"

			local body = front .. "# " .. args.title .. "\n\n" .. args.content
			local ok, err = pcall(vim.fn.writefile, vim.split(body, "\n", { plain = true }), path)
			if not ok then return "Error writing note: " .. tostring(err) end
			return "Note saved: " .. path
		end,
	},
}

return M
