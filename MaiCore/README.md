# MaiCore

MaiCore is the provider-neutral agent runtime shared by the `pmai` command-line
client and PocketMai. Concrete integrations are separate products:
`MaiOpenAI`, `MaiMCP`, and `MaiVisionOCR`. `MaiVisual` adds the SwiftTUI
terminal workspace used by the CLI's `/visual` command and is the package's only
external dependency; PocketMai does not link it. Each registers through the same plugin
API available to third-party providers. Together they support structured
message content, multimodal requests, native tool calls, approvals, MCP
Streamable HTTP servers, and bounded child agents.

Run the offline REPL from the repository root:

```sh
make repl
```

`make repl` automatically loads an optional repository-local `env.sh`. The
ad-hoc provider settings are `PMAI_PROVIDER`, `PMAI_MODEL`, `PMAI_BASE_URL`,
and `PMAI_API_KEY`; the older `MAI_*` names remain supported for compatibility.
Keep `env.sh` local because it can contain credentials.

Print a complete configuration template:

```sh
make repl ARGS=--print-config
```

Load a configuration explicitly:

```sh
make repl ARGS='--config MaiCore/pmai.example.json'
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

`/copy` puts the last assistant reply on the system clipboard as plain text,
without reasoning blocks. `/copy N` copies the last `N` conversation messages
instead; several messages are labelled `User:`, `Assistant:`, and `Tool:`, while
tool calls, tool results, and attachments are summarized on their own lines.
Instructions are never copied. macOS uses the native pasteboard; other platforms
use the first of `wl-copy`, `xclip`, `xsel`, `pbcopy`, or `clip.exe` found in
`PATH`.

`/visual` hands the terminal to a [SwiftTUI](https://swifttui.sh/) workspace
built by the `MaiVisual` module and returns to the prompt on `Ctrl+C`, `/exit`,
or the REPL button. The Chats tab keeps several conversations in a sidebar and
shows them in framed panes. Every action is reachable in three portable ways:
the button toolbar above the panes (Tab moves between controls, Return
activates, the mouse works too), the searchable command menu on `Ctrl+K` or
`F2`, and slash commands typed into a pane: `/pane new|split|down|close|next|prev`,
`/tab chats|providers|mcp|tools|agents`, `/menu`, `/sidebar`, and `/cancel`.
Alt chords (`Alt+N`, `Alt+V`, `Alt+S`, `Alt+X`, `Alt+arrows`, `Alt+B`,
`Alt+K`, `Alt+C`, `Alt+1` to `Alt+5`) are listed in the menu and work only where
the terminal sends Alt as an Escape prefix. The REPL's own slash commands run
unchanged on the focused pane's conversation: `/chat list`, `/model`, `/agent`,
`/image`, `/copy`, `/clear`, and the rest. Command output appears above the
input until Escape closes it. The Providers, MCP, Tools, and Agents tabs
register new OpenAI-compatible or plugin providers, connect Streamable HTTP MCP
servers, toggle the tools each conversation may call, register plugin tool
sources, switch agents, and save the focused conversation as a named agent.
Registrations apply to the running session immediately and are saved atomically
to the loaded config path, or to `~/.config/pmai/config.json` when none was
loaded. Tool approvals raised
while the workspace is open appear as a sheet instead of a stdin prompt. Leaving
the workspace makes the focused conversation the REPL conversation; the other
conversations and the pane layout are kept in memory for the next `/visual`.
Visual mode needs an interactive terminal and, on macOS, version 15 or later.

`/attach PATH` queues a document for the next message. Word files and PDFs
are converted to Markdown (scanned PDF pages go through on-device OCR on Apple
platforms), JSON files become an indented outline, and other text files are
attached verbatim; images are attached at medium size, so use `/image` for other
sizes or OCR. `/attach clear` drops everything queued. The converters live in
the `MaiDocuments` module, which PocketMai links as well, so the app, the CLI,
and its visual mode share one implementation. `MaiDocuments` needs PDFKit for
PDFs, so PDF conversion is unavailable on Linux while Word, JSON, and text work
everywhere.

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

Configuration is discovered in this order: `--config`, `PMAI_CONFIG`,
`./pmai.json`, and `~/.config/pmai/config.json`. Secrets should normally use
`apiKeyEnvironment`, `bearerTokenEnvironment`, or `headerEnvironment` instead
of being stored directly in JSON.

The text REPL persists independent chats to `~/.config/pmai/chats.json` and its
editable Up/Down input history to `~/.config/pmai/history.json`; `PMAI_STATE`,
`PMAI_HISTORY`, `--state`, and `--history` override those paths. `/chat list`,
`new`, `use`, `next`, `previous`, `rename`, and `close` manage chats, while
`messages`, `log`, `edit`, `remove`, `undo`, `trim`, and `clear` operate on the
active transcript. Tab completes commands, chat selectors, agents, and
providers. `/agent add NAME PROVIDER BASE_URL MODEL SYSTEM_PROMPT` creates or
updates a reusable agent, and `/provider`, `/model`, and `/proxy` save changes
back to that agent in the shared configuration.

Each prompt is preceded by a colored separator so prompts remain easy to find
in terminal scrollback. Long input scrolls horizontally and is printed in full
when submitted. `/set ui.` lists the persisted terminal styling options;
`ui.bgline`, `ui.fgprompt`, `ui.bgprompt`, `ui.fgcolor`, and `ui.bgcolor` accept
named ANSI colors, `rgb:RGB`, or `none`, while `ui.bold` accepts `on` or `off`.
`Ctrl+A` and `Ctrl+E` move to the beginning and end, `Ctrl+W` deletes the
previous word, and `Ctrl+C` cancels the active model or tool run without leaving
the REPL. `Ctrl+Z` suspends pmai with the terminal restored; run `fg` in the
shell to resume the same input or active run.

Native tools are presented as plugin-defined capability groups instead of one
checkbox per provider-visible function. `/tools` lists the groups, `/tools
enable|disable GROUP` changes the active agent, and `/tools show GROUP` displays
the expanded tool names and settings. `/tools set GROUP OPTION VALUE` persists
typed group settings and reloads the source; for example, Mastodon's instance,
API-key environment variable, and write permission are configured this way.
Visual mode renders the same descriptors as checkboxes and typed fields. Group
selections live on each `AgentDefinition`, while source credentials and options
live on `ConfiguredToolSource`, so every host uses the same configuration and
plugin API. Older native plugins without group metadata are grouped by their
tool-name prefix.

MCP tool names are namespaced as `<toolNamePrefix>::<remoteName>`, or
`<server-id>::<remoteName>` when no prefix is configured. Agents explicitly
list the tools and child agents they are allowed to use. `MaiStandardToolsPlugin`
provides `echo`, date/time, calculator, network, and workspace-scoped Files tools.
The `files` group can list files, find approximate names, grep bounded UTF-8
content, convert DOCX/PDF/JSON documents, write or append text, create folders,
rename entries, and delete them. `filesRoot` confines every relative
path to one directory (including symlink checks), while `filesWriteEnabled`
removes the mutation tools when disabled. Mutations still go through normal
confirmation, and deletion is marked dangerous. `read_text_file` remains
available for compatibility with older agent configurations.
Streamable HTTP support is supplied by `MaiMCPPlugin`, so the transport is not a
dependency of the core runtime.

The example MCP entry is disabled so the example remains safe to inspect. Set
its URL, enable it, discover its tools with `/tools`, and add the names you want
to an agent's `toolNames` list. Set `useToolProxy` on an agent when models should
see only MaiCore's shared `list-tools` and `call-tool` interface.
