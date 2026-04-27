# Local LLM setup with LiteLLM + llama-swap

This is the stack the plugin was built against. The chain is:

```
Neovim (barebones-chat.nvim)
  → LiteLLM proxy  (port 4000, running as a Windows service via NSSM)
    → llama-swap   (manages llama.cpp model loading/unloading)
      → llama.cpp
```

---

## llama-swap

[llama-swap](https://github.com/mostlygeek/llama-swap) sits in front of llama.cpp and swaps models in and out on demand. You define a config that maps model names to llama.cpp server invocations; llama-swap starts and stops servers as requests come in.

Example `config.yaml`:

```yaml
models:
  bonsai:
    cmd: llama-server --model /models/bonsai-8b.gguf --port 8080 --ctx-size 8192
    proxy: http://localhost:8080
```

llama-swap exposes an OpenAI-compatible API, so you can point anything at it directly — but LiteLLM sits in front to give you a single stable endpoint regardless of which model you're swapping to.

---

## LiteLLM

[LiteLLM](https://github.com/BerriAI/litellm) is a proxy that translates between OpenAI's API format and a wide range of backends. Here it's used to give llama-swap a fixed URL (`localhost:4000`) and handle any format differences.

Example `litellm_config.yaml`:

```yaml
model_list:
  - model_name: local/bonsai
    litellm_params:
      model: openai/bonsai
      api_base: http://localhost:8888   # llama-swap port
      api_key: anything
```

Run it with:

```bash
litellm --config litellm_config.yaml --port 4000
```

---

## NSSM — running LiteLLM as a Windows service

[NSSM](https://nssm.cc) (Non-Sucking Service Manager) wraps any executable as a Windows service so LiteLLM starts automatically with the machine.

```powershell
nssm install LiteLLM "C:\Python\Scripts\litellm.exe"
nssm set LiteLLM AppParameters "--config C:\llm\litellm_config.yaml --port 4000"
nssm set LiteLLM AppDirectory "C:\llm"
nssm start LiteLLM
```

After this, `http://localhost:4000` is always available — no terminal to keep open.

---

## Neovim config

```lua
-- ~/.config/nvim/lua/plugins/barebones-chat.lua
return {
  {
    dir = vim.fn.expand '~/projects/barebones-chat.nvim',
    name = 'barebones-chat',
    config = function()
      local barebones = require 'barebones-chat'

      barebones.setup {
        base_url = 'http://localhost:4000',
        api_key  = os.getenv 'LITELLM_API_KEY' or 'anything',
        model    = 'local/bonsai',  -- matches model_name in litellm_config.yaml

        system_prompt = 'You are a helpful assistant.',

        hooks = {
          -- append visual selection when one exists
          function(prompt, buf)
            local selection, _ = barebones.utils.get_visual_selection()
            if selection and selection ~= '' then
              return prompt .. '\n\n<visual_selection>\n' .. selection .. '\n</visual_selection>'
            end
            return prompt
          end,
        },

        tools = {},
      }
    end,
    keys = {
      { '<leader>ac', '<cmd>Barebones<cr>', desc = 'Barebones' },
    },
  },
}
```

---

## Request flow

1. You press `<CR>` in the Barebones buffer
2. Hooks run — visual selection is appended if present
3. The system prompt and user message are assembled into an OpenAI-format payload
4. `curl` POSTs to `http://localhost:4000/v1/chat/completions` with `model: local/bonsai`
5. LiteLLM forwards the request to llama-swap at port 8888
6. llama-swap starts the bonsai llama.cpp server if it isn't already running
7. The response streams back as SSE, rendered into the buffer in real time
