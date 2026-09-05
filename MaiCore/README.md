# MaiCore

MaiCore is the provider-neutral agent runtime shared by the `pmai` command-line
client and PocketMai. Concrete integrations are separate products:
`MaiOpenAI`, `MaiMCP`, and `MaiVisionOCR`. `MaiVisual` adds the SwiftTUI
terminal workspace used by the CLI's `/visual` command and is the package's only
external dependency; PocketMai does not link it. Each registers through the same plugin
API available to third-party providers. Together they support structured
message content, multimodal requests, native tool calls, approvals, MCP
Streamable HTTP servers, CLI-only stdio MCP processes, and bounded child agents.

Run the offline REPL from the repository root:

```sh
make repl
```

`make repl` loads an optional repository-local `env.sh` as a fallback when no
ad-hoc provider variable is already present in the calling shell. The ad-hoc
provider settings are `PMAI_PROVIDER`, `PMAI_MODEL`, `PMAI_BASE_URL`, and
`PMAI_API_KEY`; the older `MAI_*` and `OPENAI_*` names remain supported for
compatibility. These variables override the selected agent's provider for the
current process. `/baseurl` shows the effective URL and also identifies a
different persisted URL when one is being overridden. Export `PMAI_API_KEY=`
to explicitly send no API key and suppress configured or legacy API-key
fallbacks; merely unsetting it allows those fallbacks to be used.
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
`PMAI_HISTORY`, `--state`, and `--history` override those paths. Like the
PocketMai app, every launch opens a fresh chat that is named after its first
message; chats that never receive a message are dropped rather than piling up,
and `--resume` reopens the most recently updated chat instead. `/chat list`
shows the earlier chats grouped by day (Today, Yesterday, This week, Last week,
then dates), newest first, with their agent, size, and last-update time, and
lists archived chats last; `/chat list active` and `/chat list archived` narrow
it down. `/chat use INDEX|ID|TITLE`, `next`, and `previous` switch chats,
`/chat info` shows when a chat started and was last updated, `/chat archive`
moves a chat out of the active list (archiving the current chat starts a new
one), `/chat unarchive` brings it back, and `new`, `rename`, and `close` manage
chats, while `messages`, `log`, `edit`, `remove`, `undo`, `trim`, and `clear`
operate on the active transcript. Tab completes commands, chat selectors,
agents, and providers. `/agent add NAME PROVIDER BASE_URL MODEL SYSTEM_PROMPT` creates or
updates a reusable agent, and `/provider`, `/model`, and `/proxy` save changes
back to that agent in the shared configuration.

Use `/baseurl URL` to change the current provider endpoint. To edit another
provider, select it first with `/provider ID`. The provider is replaced in the
live runtime and the new URL is saved immediately. `/provider baseurl URL`
remains an alias. In `/visual`, open the Providers tab, choose **Edit** beside a
configured provider, change **Base URL**, and choose **Update**.

Each prompt is preceded by a colored separator so prompts remain easy to find
in terminal scrollback. Long input scrolls horizontally and is printed in full
when submitted. `/set ui.` lists the persisted terminal styling options;
`ui.bgline`, `ui.fgprompt`, `ui.bgprompt`, `ui.fgcolor`, and `ui.bgcolor` accept
named ANSI colors, `rgb:RGB`, or `none`, while `ui.bold` and `ui.markdown`
accept `on` or `off`. `ui.toolResultLines` controls how many leading lines of
each tool result are shown in the terminal (default `3`; `0` restores the
compact status-only display). Tool lifecycle messages are green, with failed
results shown in red. `/set limits.` shows the per-run limits of the current
chat's agent; `/set limits.maxToolCalls N` and `/set limits.maxModelTurns N`
change them and persist the change into that agent's configuration. The
`--max-tool-calls N` and `--max-turns N` flags override both for one launch.
`/set toolCallingStrategy text|xml|json` forces message-based tool calling for
models without native tools; `automatic` prefers native calls and otherwise
uses JSON, while `native` requires native support. The selected mode is saved
on the agent.
When a run spends its tool call budget, the remaining calls of that reply are
answered with an error and the model is asked to answer without tools instead
of the run failing. Replies are rendered as styled markdown while they stream:
headings, lists, task lists, quotes, rules, fenced code, footnotes, and pipe
tables whose cells keep their bold, code, and link styling and wrap to the
terminal width. `--no-markdown` or `ui.markdown off` prints replies verbatim,
output that is not a terminal stays verbatim unless `--markdown` is given, and
`NO_COLOR` keeps the structure without colors. The visual workspace renders the
same markdown inside its panes.
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
`<server-id>::<remoteName>` when no prefix is configured. Connecting an enabled
MCP exposes all of that server's discovered tools to every agent; the server is
the enable/disable unit. Obsolete names left in an agent after an MCP rename are
ignored instead of preventing the REPL from starting. Agents still explicitly
list non-MCP tools and child agents they are allowed to use.
`MaiStandardToolsPlugin` provides `echo`, date/time, calculator, network, and
workspace-scoped Files tools.

Subagents are disabled by default. Set an agent's `limits.maxSubagents` above
zero and populate `subagentNames` to expose the runtime-managed tools.
`spawn_agent` runs one child synchronously for compatibility. `agent_launch`
starts a child with a specific `agent` and `prompt`, returning a structured run
`id` immediately. `agent_status` polls one id or lists the orchestrator's jobs
without waiting, while `agent_result` waits when necessary and returns the final
child content. Background children survive across orchestrator turns, and
`maxSubagents` caps concurrent work; a completed child releases its slot.

In the `pmai` REPL, `/mcp list` shows configured servers and their live state.
Add and connect a stdio server without editing JSON using
`/mcp add COMMAND [ARG ...]`; the command basename becomes its ID. Use
`/mcp add --name ID [options] -- COMMAND [ARG ...]` when a different ID or
options are needed. `/mcp enable ID` and `/mcp disable ID` reconnect or
disconnect the complete server tool set and persist the state. Run `/mcp` for
the full option list. The legacy `/mcps` spelling remains a list alias.

The `files` group can list files, find approximate names, grep bounded UTF-8
content, convert DOCX/PDF/JSON documents, write or append text, create folders,
rename entries, and delete them. Existing files are edited in place with
`files_patch` (unique literal or regex replacement) or `files_replace_range`
(1-based line ranges); both return a unified diff. For large source files,
`files_get_function` finds a function by name and reports its complete line and
UTF-8 byte bounds plus a body revision. `files_set_function` uses that revision
to atomically replace only the body, preserving concurrent edits to other
functions and rejecting stale edits to the same function. Its lightweight
locator supports common brace-, indentation-, and `end`-delimited languages,
including HolyC `.hc` files. `files_write` refuses to replace a non-empty file unless
`overwrite: true` is passed, so a model cannot clobber a file it meant to
patch. `filesRoot` confines every relative
path to one directory (including symlink checks), while `filesWriteEnabled`
removes the mutation tools when disabled. Mutations still go through normal
confirmation, and deletion is marked dangerous. `read_text_file` remains
available for compatibility with older agent configurations.

With the default Files workspace (no explicit `filesRoot`, or `filesRoot: "."`),
`/cwd` prints the process working directory and `/cd PATH` changes it. The model
can use `files_chdir` with the same behavior. The default workspace resolves its
root on each tool call, keeping an installed `pmai` binary aligned with the
directory from which it was launched. An explicit `filesRoot` remains fixed and
does not expose `files_chdir`.
The `run` group executes code on this computer with the privileges of the
`pmai` process: `run_system` passes one command line to `sh -c`, while
`run_sh`, `run_python`, and `run_js` save a script to a temporary file and run
it with the configured shell, Python, or Node.js interpreter (`runShell`,
`runPython`, `runNode`; names are looked up in `PATH`, and leading arguments
such as `node --no-warnings` are honoured). Every call may pass `args`, `stdin`,
`cwd`, and `timeout_seconds`; stdout and stderr are captured with a 100 KB cap
per stream, the process is killed after the timeout (`runTimeoutSeconds`,
default 60), and `Ctrl+C` terminates it. All four tools are marked dangerous,
so they follow the `dangerous` approval setting, and the group is absent on
iOS. Use `/tools disable run` to remove them from an agent.
Streamable HTTP support is supplied by `MaiMCPPlugin`, so the transport is not a
dependency of the core runtime.

On non-iOS hosts, `MaiMCPPlugin` also supports the standard stdio MCP
configuration fields. `kind` may be omitted when `command` is present:

```json
{
  "id": "local-tools",
  "command": "npx",
  "args": ["-y", "your-mcp-package"],
  "env": {"EXAMPLE_API_KEY": "value"},
  "cwd": ".",
  "toolNamePrefix": "local"
}
```

The command inherits the `pmai` environment, with `env` values taking
precedence. A bare command is resolved through `PATH`; `cwd` is optional. Stdio
MCP support, including its subprocess factory and public transport types, is
compiled out on iOS. The iOS app continues to support Streamable HTTP only.

The example MCP entry is disabled so the example remains safe to inspect. Set
an HTTP URL or stdio command and enable it to expose all discovered tools. Set
`useToolProxy` on an agent when models should see only MaiCore's shared
`list-tools` and `call-tool` interface.

Agents can force MaiCore's emulated tool loop with `toolCallingStrategy` set to
`text`, `xml`, or `json`. These modes send tool instructions as messages, parse
the model's response, execute the calls, return results, and continue until the
model answers. `automatic` uses native calls when the provider supports them
and JSON emulation otherwise; `native` requires provider-native tool calling.
