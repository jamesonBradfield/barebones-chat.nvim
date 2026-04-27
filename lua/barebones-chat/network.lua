local M = {}

--- Streams an OpenAI-compatible SSE request via curl subprocess.
--- Uses vim.fn.jobstart so callbacks run on the Neovim event loop —
--- no vim.schedule needed, no plenary dependency.
---
--- @param payload table JSON payload
--- @param opts table { url, headers, on_chunk, on_tool_call, on_complete, on_error }
function M.stream_request(payload, opts)
    local has_error = false

    local cmd = { "curl", "-sN", "-X", "POST", opts.url }
    for key, value in pairs(opts.headers) do
        table.insert(cmd, "-H")
        table.insert(cmd, key .. ": " .. tostring(value))
    end
    -- jobstart passes args directly to the process, no shell escaping needed
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
                elseif data.choices and data.choices[1] and data.choices[1].delta then
                    local delta = data.choices[1].delta
                    if delta.content and delta.content ~= vim.NIL then
                        opts.on_chunk(delta.content)
                    end
                    if delta.tool_calls then
                        opts.on_tool_call(delta.tool_calls)
                    end
                elseif data.type == "content_block_delta" and data.delta and data.delta.text then
                    opts.on_chunk(data.delta.text)
                elseif data.type == "content_block_start" and data.content_block and data.content_block.type == "tool_use" then
                    opts.on_tool_call({ data.content_block })
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
            if opts.on_complete then opts.on_complete() end
        end,
    })
end

return M
