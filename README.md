# barebones-chat.nvim

A Neovim plugin for streaming LLM completions from any OpenAI-compatible endpoint. No built-in RAG, no slash commands, no hardcoded prompt templates -- just a prompt buffer, an SSE streaming client, and a hook pipeline. Requires Neovim 0.10+ and `curl` on `$PATH`.

## Quickstart

```lua
-- lazy.nvim
{
  "jamesonBradfield/barebones-chat.nvim",
  config = function()
    require("barebones-chat").setup({
      base_url = "http://localhost:4000",
      api_key  = os.getenv("LITELLM_API_KEY") or "anything",
      model    = "your-model-name",
      system_prompt = "You are a helpful assistant.",
      hooks = {},
      tools = {},
    })
  end,
  keys = { { "<leader>ac", "<cmd>Barebones<cr>", desc = "Barebones" } },
}
```

Run `:Barebones` to open the prompt buffer. Press `<CR>` in normal mode to submit.

## Hooks

Hooks are the primary extension point. `hooks` is an ordered list of functions, each receiving the full prompt string and the buffer handle, each returning the modified prompt. They are chained: the output of one is the input of the next. Returning `nil` passes the prompt through unchanged.

```lua
hooks = {
  -- expand @path references to absolute file paths
  function(prompt, buf)
    return prompt:gsub("@([%w%./%-_]+)", function(p)
      return vim.fn.fnamemodify(p, ":p")
    end)
  end,

  -- inject visual selection when one exists
  function(prompt, buf)
    local selection = require("barebones-chat").utils.get_visual_selection()
    if selection and selection ~= "" then
      return prompt .. "\n\n<visual_selection>\n" .. selection .. "\n</visual_selection>"
    end
    return prompt
  end,

  -- append git status
  function(prompt, buf)
    return prompt .. "\n\n<git_status>\n" .. vim.fn.system("git status --short") .. "</git_status>"
  end,
}
```

Each hook has full access to the Neovim API, the filesystem, shell commands, and anything else reachable from Lua. There are no restrictions on what a hook can do to the prompt.

## Configuration

### System prompt

```lua
system_prompt = "You are a helpful assistant. Reply concisely."
```

Sent as `{ role = "system" }` as the first message.

### Chunk processor

Intercepts each streamed text delta before it reaches the buffer. Return `nil` to drop a chunk.

```lua
chunk_processor = function(text)
  text = text:gsub("<thinking>.-</thinking>", "")
  if text == "" then return nil end
  return text
end
```

### Tools

Named Lua functions the LLM can invoke via function calling. Formatted as OpenAI tool definitions automatically.

```lua
tools = {
  run_tests = {
    description = "Run the test suite and return output.",
    modifies_state = true,
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to test file or directory." }
      },
      required = { "path" }
    },
    execute = function(args)
      return vim.fn.system("pytest " .. vim.fn.shellescape(args.path))
    end
  }
}
```

When `modifies_state = true` the plugin prompts before executing:

```
[Barebones] LLM wants to run tool 'run_tests'
Arguments: {"path": "tests/"}

Allow execution? [Y/n]:
```

## Local LLM setup

See [docs/local-llm-setup.md](docs/local-llm-setup.md) for a full walkthrough of the [LiteLLM](https://github.com/BerriAI/litellm) + [llama-swap](https://github.com/mostlygeek/llama-swap) stack this plugin was built against, including running LiteLLM as a Windows service with NSSM.
