# MaiCore

MaiCore is the UI-independent agent runtime shared by the `mai` command-line
client and, after the API stabilizes, PocketMai. It supports structured message
content, multimodal OpenAI-compatible requests, native tool calls, approvals,
MCP Streamable HTTP servers, and bounded child agents.

Run the offline REPL from the repository root:

```sh
make repl
```

Print a complete configuration template:

```sh
make repl ARGS=--print-config
```

Load a configuration explicitly:

```sh
make repl ARGS='--config MaiCore/mai.example.json'
```

Inside the REPL, `/models` queries the current provider's model catalog and
`/models PROVIDER` queries another registered provider without switching the
session. Use `/model NAME` to select one of the returned model IDs.

Use `/chat list` for a compact indexed history or `/chat log` for the complete
structured transcript, including attachments, reasoning, tool calls, tool
results, and structured MCP output. The current in-memory conversation can be
changed at any point with `/chat edit N TEXT`, `/chat remove N`, `/chat undo
[N]`, `/chat trim N`, and `/chat clear`. Trimming keeps messages through `N`;
linked tool-call transactions are kept structurally valid when removing or
trimming messages.

Configuration is discovered in this order: `--config`, `MAI_CONFIG`,
`./mai.json`, and `~/.config/mai/config.json`. Secrets should normally use
`apiKeyEnvironment`, `bearerTokenEnvironment`, or `headerEnvironment` instead
of being stored directly in JSON.

MCP tool names are namespaced as `<toolNamePrefix>::<remoteName>`, or
`<server-id>::<remoteName>` when no prefix is configured. Agents explicitly
list the tools and child agents they are allowed to use. The built-in CLI host
tools are `echo`, `current_time`, and `read_text_file`.

The example MCP entry is disabled so the example remains safe to inspect. Set
its URL, enable it, discover its tools with `/tools`, and add the names you want
to an agent's `toolNames` list.
