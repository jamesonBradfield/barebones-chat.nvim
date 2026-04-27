# Security

## Trust model

The plugin has two trust boundaries.

**User-controlled (trusted):** Everything in `setup()` -- `base_url`, `api_key`, `hooks`, `tools`, `chunk_processor`. These run as Lua with full Neovim and system privileges. You are responsible for what you put here.

**LLM-controlled (untrusted):** The text content of completions, and the tool call names and arguments embedded in the response. This data is parsed and dispatched by the plugin. Treat it as untrusted input.

---

## What the plugin protects against

**Shell injection via curl.** The HTTP request is made with `vim.fn.jobstart`, which passes arguments as an array directly to the process -- no shell is involved. The URL, headers, and body cannot be used to inject shell commands regardless of their content.

**Arbitrary tool invocation.** The LLM can only call tools that are explicitly registered in your `tools = {}` config. An unregistered tool name in a response is a no-op.

**LLM response execution.** Streamed text is written to the buffer as display only. The plugin never evals, execs, or shell-passes the content of a completion.

---

## What the plugin does not protect against

**Silent tool execution.** Tools without `modifies_state = true` fire immediately when the LLM calls them, with no prompt. If the LLM is manipulated into calling a registered tool with crafted arguments, it runs.

**Tool argument validation.** Arguments come from the LLM as JSON and are passed raw to `execute`. The plugin does no schema validation beyond parsing. A tool that does `vim.fn.system(args.cmd)` is fully exploitable if the model can be made to call it.

**Hook privilege.** Hooks are plain Lua functions with full access to the Neovim API, the filesystem, and the shell. There is no sandbox. A hook sourced from an untrusted config file is equivalent to arbitrary code execution.

**Prompt injection into the model.** The plugin cannot distinguish genuine model output from attacker-influenced output. If the model is susceptible to prompt injection (e.g. via content in a file you pasted), the plugin will faithfully execute any tool calls that result.

**Plaintext HTTP.** Requests go to `base_url` as-is. Sending to a non-localhost HTTP endpoint on an untrusted network leaks your prompts and opens the response stream to tampering.

---

## Practical guidance

**Put `modifies_state = true` on every tool that touches the filesystem, runs shell commands, or mutates buffers.** This is the only user-facing execution gate the plugin provides.

**Do not register tools you would not want called with arbitrary arguments.** The LLM controls the arguments, not you.

**Treat hooks like any other Lua in your config.** Read them before using them. Do not copy hooks from untrusted sources.

**Use localhost or HTTPS endpoints only.** Avoid sending prompts over plain HTTP on a network you do not fully control.

**Keep your API key in an environment variable**, not hardcoded in a config file tracked by git.
