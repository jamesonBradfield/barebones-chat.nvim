# barebones-chat.nvim

A minimal, unopinionated "agentic micro-framework" for Neovim. 

Unlike bloated AI plugins with hardcoded commands and proprietary RAG implementations, `barebones-chat.nvim` does exactly one thing well: it provides a robust UI primitive and an event loop that you can extend completely via your `init.lua`. It acts as a bridge between the Neovim API and LLM function calling.

## Core Philosophy
1. **The Buffer/UI Manager**: A clean, non-blocking chat interface that renders Markdown beautifully.
2. **The "Dumb" Curl Wrapper**: A pure, asynchronous HTTP client wrapping `plenary.curl` that handles SSE streaming and tool calls.
3. **The Extensibility API**: Define your own context hooks and native Lua tools.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "your-username/barebones-chat.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
        -- See configuration below
    end
}
```

## Configuration & Examples

The plugin exposes a `setup` function where you can define your provider, context hooks, and custom tools.

### 1. Default Tool Example: Visual Selection Find & Replace

This example demonstrates how to inject the current visual selection into the prompt and provide the LLM with a tool to mutate it.

```lua
local barebones = require("barebones-chat")

barebones.setup({
    provider = "anthropic",
    model = "claude-3-7-sonnet",
    
    -- Hook to inject dynamic context into the system prompt
    on_submit = function(prompt, chat_buffer)
        local selection, _ = barebones.utils.get_visual_selection()
        if selection and selection ~= "" then
            return prompt .. "\n\n<visual_selection>\n" .. selection .. "\n</visual_selection>"
        end
        return prompt
    end,

    -- Define tools natively in Lua for the LLM to call
    tools = {
        -- Use the built-in default tool for replacing visual selections
        replace_visual_selection = barebones.default_tools.replace_visual_selection
    }
})
```

### 2. User Config Example: Exposing `_G` Functions (e.g., Pytest)

You can easily expose shell commands or native Neovim functions to the LLM. Because `modifies_state = true` is set, the plugin will automatically prompt you with a `[Y/n]` confirmation before executing the command.

```lua
local barebones = require("barebones-chat")

barebones.setup({
    provider = "openai",
    model = "gpt-4o",
    
    on_submit = function(prompt, chat_buffer)
        return prompt
    end,

    tools = {
        run_pytest = {
            description = "Run pytest on a specific file and return the output.",
            modifies_state = true, -- Requires user confirmation [Y/n]
            parameters = {
                type = "object",
                properties = {
                    filepath = {
                        type = "string",
                        description = "The path to the test file to run."
                    }
                },
                required = { "filepath" }
            },
            execute = function(args)
                -- Run the shell command synchronously and capture output
                local cmd = "pytest " .. vim.fn.shellescape(args.filepath)
                local output = vim.fn.system(cmd)
                
                -- Return the output back to the LLM
                return output
            end
        }
    }
})
```

## Usage

Run `:BarebonesChat` to open the chat buffer. Type your prompt and press `<CR>` in normal mode to submit.

## Safety

When the LLM attempts to call a tool where `modifies_state = true`, `barebones-chat.nvim` intercepts the execution and prompts you in the Neovim command line:

```
[Barebones Chat] LLM wants to run tool 'run_pytest'
Arguments: {"filepath": "tests/test_main.py"}

Allow execution? [Y/n]: 
```
