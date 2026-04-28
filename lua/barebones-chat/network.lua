local M = {}

--- Streams an OpenAI-compatible SSE request via curl subprocess.
--- Tool calls are accumulated across chunks and fired once (complete) in on_exit.
---
--- @param payload table JSON payload
--- @param opts table { url, headers, on_chunk, on_tool_call, on_complete, on_error }
function M.stream_request(payload, opts)
    local has_error = false
    -- index (1-based) -> {id, function_name, arguments}
    local tc_bufs = {}

    local cmd = { "curl", "-sN", "-X", "POST", opts.url }
    for key, value in pairs(opts.headers) do
        table.insert(cmd, "-H")
        table.insert(cmd, key .. ": " .. tostring(value))
    end
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(payload))

    return vim.fn.jobstart(cmd, {
        stdout_buffered = false,

        on_stdout = function(_, lines, _)
            for _, line in ipairs(lines) do
                line = line:gsub('\r$', '')
                if not line:match('^data: ') then goto continue end

                local data_str = line:sub(7)
                if data_str == '' or data_str == '[DONE]' then goto continue end

                local ok, data = pcall(vim.json.decode, data_str)
                if not ok or not data then goto continue end

                if data.error then
                    local msg = type(data.error) == "table"
                        and (data.error.message or vim.json.encode(data.error))
                        or tostring(data.error)
                    if opts.on_error and not has_error then
                        has_error = true
                        opts.on_error(msg)
                    end

                -- OpenAI streaming delta
                elseif data.choices and data.choices[1] and data.choices[1].delta then
                    local delta = data.choices[1].delta
                    if delta.content and delta.content ~= vim.NIL then
                        opts.on_chunk(delta.content)
                    end
                    -- accumulate tool call chunks by index
                    if delta.tool_calls then
                        for _, tc in ipairs(delta.tool_calls) do
                            local idx = (tc.index or 0) + 1
                            if not tc_bufs[idx] then
                                tc_bufs[idx] = { id = "", function_name = "", arguments = "" }
                            end
                            local buf = tc_bufs[idx]
                            if tc.id and tc.id ~= "" then buf.id = tc.id end
                            if tc["function"] then
                                if tc["function"].name and tc["function"].name ~= "" then
                                    buf.function_name = tc["function"].name
                                end
                                if tc["function"].arguments then
                                    buf.arguments = buf.arguments .. tc["function"].arguments
                                end
                            end
                        end
                    end

                -- Anthropic: tool_use block start (name + id, no args yet)
                elseif data.type == "content_block_start" and data.content_block then
                    local cb = data.content_block
                    if cb.type == "tool_use" then
                        local idx = (data.index or 0) + 1
                        tc_bufs[idx] = { id = cb.id or "", function_name = cb.name or "", arguments = "" }
                    elseif cb.type == "text" then
                        -- handled below via content_block_delta
                    end

                -- Anthropic: streaming text or tool argument delta
                elseif data.type == "content_block_delta" and data.delta then
                    if data.delta.text then
                        opts.on_chunk(data.delta.text)
                    elseif data.delta.type == "input_json_delta" and data.delta.partial_json then
                        local idx = (data.index or 0) + 1
                        if tc_bufs[idx] then
                            tc_bufs[idx].arguments = tc_bufs[idx].arguments .. data.delta.partial_json
                        end
                    end

                elseif data.message and data.message.content then
                    opts.on_chunk(data.message.content)
                end

                ::continue::
            end
        end,

        on_stderr = function(_, lines, _)
            if has_error then return end
            local msg = table.concat(
                vim.tbl_filter(function(l) return l ~= '' end, lines),
                "\n"
            )
            if msg ~= '' and opts.on_error then
                has_error = true
                opts.on_error(msg)
            end
        end,

        on_exit = function(_, code, _)
            if code ~= 0 and not has_error and opts.on_error then
                opts.on_error("curl exited with code " .. tostring(code))
            end
            -- fire complete tool calls once, after streaming is done
            local complete = {}
            for _, tc in ipairs(tc_bufs) do
                if tc.function_name ~= "" then
                    table.insert(complete, tc)
                end
            end
            if #complete > 0 and opts.on_tool_call then
                opts.on_tool_call(complete)
            end
            if opts.on_complete then opts.on_complete(#complete > 0) end
        end,
    })
end

return M
