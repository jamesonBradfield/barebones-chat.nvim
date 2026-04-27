# barebones-chat.nvim

A minimal Neovim plugin that gives you a prompt buffer wired to any OpenAI-compatible LLM endpoint. No RAG, no agents, no slash commands, no hardcoded workflows — just the primitive.

Most AI plugins (Avante, CodeCompanion, etc.) make strong assumptions: they own the prompt format, the context strategy, the tool set, and the UI. This plugin owns none of those things. It handles the buffer and the HTTP; you handle everything else in your own config.

---

## Architecture

Three files, three concerns:

### `network.lua` — HTTP streaming

Fires a `curl` subprocess via `vim.fn.jobstart` and parses the SSE stream line-by-line. Callbacks run on the Neovim event loop, so no `vim.schedule` juggling is needed at the call site.

Handles the OpenAI streaming delta format (`choices[0].delta.content`), Anthropic's `content_block_delta`, and Ollama's `message.content` — whichever your endpoint emits.

```
stream_request(payload, opts)
  opts.url          -- full endpoint URL
  opts.headers      -- table of HTTP headers
  opts.on_chunk     -- called with each text delta string
  opts.on_tool_call -- called with tool_calls array
  opts.on_error     -- called with error string
  opts.on_complete  -- called when the stream closes
```

No provider logic lives here. It is a pure streaming HTTP primitive.

### `ui.lua` — buffer management

Creates a single scratch buffer in a vertical split, sets `filetype=markdown`, and exposes two functions:

- `create_buffer()` — opens or focuses the buffer
- `append_text(str)` — appends streamed text non-destructively, scrolling to the bottom

The buffer handle is exposed as `ui.buf` for hooks that need to inspect it.

### `init.lua` — wiring

Owns configuration, runs the hooks pipeline, builds the message payload, and calls into `network` and `ui`. Also holds `M.utils` (visual selection helper) and `M.default_tools` (the `replace_visual_selection` example).

---

## Extensibility

### Hooks — prompt pipeline

`hooks` is an ordered list of functions applied to the prompt before it is sent. Each function receives the full prompt string and the buffer handle, and must return the modified prompt string.

```lua
hooks = {
  function(prompt, buf)
    -- expand @path/to/file references to absolute paths
    return prompt:gsub("@([%w%./%-_]+)", function(p)
      return vim.fn.fnamemodify(p, ":p")
    end)
  end,

  function(prompt, buf)
    -- append current visual selection
    local selection, _ = require("barebones-chat").utils.get_visual_selection()
    if selection and selection ~= "" then
      return prompt .. "\n\n<visual_selection>\n" .. selection .. "\n</visual_selection>"
    end
    return prompt
  end,

  function(prompt, buf)
    -- append git status
    return prompt .. "\n\n<git_status>\n" .. vim.fn.system("git status --short") .. "</git_status>"
  end,
}
```

Hooks are chained: each receives the output of the previous one. Returning `nil` is safe — it passes the prompt through unchanged.

### Tools — LLM function calling

`tools` is a table of named functions the LLM can invoke. The plugin formats them as OpenAI-compatible tool definitions and handles the execution loop.

```lua
tools = {
  run_tests = {
    description = "Run the test suite and return output.",
    modifies_state = true,   -- triggers a [Y/n] confirmation prompt
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

When `modifies_state = true` the user is prompted before execution:

```
[Barebones] LLM wants to run tool 'run_tests'
Arguments: {"path": "tests/"}

Allow execution? [Y/n]:
```

The `execute` function can return any string — the result is displayed in the buffer.

### Chunk processor

`chunk_processor` intercepts each streamed text delta before it hits the buffer. Return `nil` to drop a chunk entirely.

```lua
chunk_processor = function(text)
  -- strip thinking tags from models that emit them
  text = text:gsub("<thinking>.-</thinking>", "")
  if text == "" then return nil end
  return text
end
```

### System prompt

```lua
system_prompt = "You are a helpful assistant. Reply concisely."
```

Injected as `{ role = "system" }` as the first message if set.

---

## Installation

```lua
-- lazy.nvim
{
  "jamesonBradfield/barebones-chat.nvim",
  config = function()
    require("barebones-chat").setup({
      base_url = "http://localhost:4000",  -- LiteLLM, Ollama, or any OpenAI-compatible endpoint
      api_key  = os.getenv("LITELLM_API_KEY") or "anything",
      model    = "your-model-name",

      system_prompt = "You are a helpful assistant.",

      hooks = {},
      tools = {},
    })
  end,
  keys = {
    { "<leader>ac", "<cmd>Barebones<cr>", desc = "Barebones" },
  },
}
```

No dependencies beyond Neovim 0.10+ and `curl` on `$PATH`.

Works out of the box with any OpenAI-compatible proxy — tested against [LiteLLM](https://github.com/BerriAI/litellm) fronting [llama-swap](https://github.com/mostlygeek/llama-swap). See [docs/local-llm-setup.md](docs/local-llm-setup.md) for a full walkthrough of that stack.

## Usage

Run `:Barebones` to open the prompt buffer. Write your prompt and press `<CR>` in normal mode to submit.
