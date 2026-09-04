# MaiCore

MaiCore is the provider-neutral agent runtime shared by the `pmai` command-line
client and PocketMai. Concrete integrations are separate products:
`MaiOpenAI`, `MaiMCP`, and `MaiVisionOCR`. Each registers through the same plugin
API available to third-party providers. Together they support structured
message content, multimodal requests, native tool calls, approvals, MCP
Streamable HTTP servers, and bounded child agents.

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

`/image` always takes a mode and a path. `tiny`, `small`, `medium`, and `big`
cap the longest edge at 100, 320, 640, and 1024 pixels; `full` preserves the
source image. `ocr` runs the separately injected `OCRProvider` and queues its
recognized text as a Markdown attachment:

```text
/image medium ./diagram.png
/image ocr ./receipt.jpg
```

The CLI installs `MaiVisionOCRPlugin`, whose on-device `VisionOCRProvider` is
selected with `kind: "vision"`. Other hosts can omit that module or provide a
different OCR implementation without coupling it to their chat/model provider;
PocketMai does this to preserve its layout-aware Markdown OCR.

The CLI also loads trusted native plugins from repeated `--plugin PATH` options
or from the configuration's `plugins` array. Relative config paths are resolved
from the config file's directory. `/plugins` shows built-in, statically linked,
and dynamically loaded plugins with their capabilities and origins. A plugin's
provider, tool-source, OCR, and MCP factory kinds are selected by the matching
`kind` fields in `providers`, `toolSources`, `ocrProviders`, and `mcpServers`.
See [PLUGIN_API.md](PLUGIN_API.md) for the versioned ABI and fixture command.

Custom model providers implement `ChatProvider` and register directly with
`AgentRuntime`. Configuration-backed hosts can additionally implement
`ConfiguredProviderFactory` and expose it from a `MaiPlugin` installed in the
shared `PluginRegistry`; provider kind identifiers and the `options` object are
open-ended, so adding a backend does not require a new MaiCore enum case. UI
settings remain host-owned and are translated into `ProviderRequest`,
`GenerationOptions`, and provider-specific configuration at the boundary.

Configuration is discovered in this order: `--config`, `MAI_CONFIG`,
`./mai.json`, and `~/.config/mai/config.json`. Secrets should normally use
`apiKeyEnvironment`, `bearerTokenEnvironment`, or `headerEnvironment` instead
of being stored directly in JSON.

MCP tool names are namespaced as `<toolNamePrefix>::<remoteName>`, or
`<server-id>::<remoteName>` when no prefix is configured. Agents explicitly
list the tools and child agents they are allowed to use. `MaiStandardToolsPlugin`
provides `echo`, `current_time`, `calculator`, and `read_text_file`; default CLI
agents select the same three tools as before, and PocketMai reuses its calculator.
Streamable HTTP support is supplied by `MaiMCPPlugin`, so the transport is not a
dependency of the core runtime.

The example MCP entry is disabled so the example remains safe to inspect. Set
its URL, enable it, discover its tools with `/tools`, and add the names you want
to an agent's `toolNames` list. Set `useToolProxy` on an agent when models should
see only MaiCore's shared `list-tools` and `call-tool` interface.
