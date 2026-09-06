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
changed at any point with `/chat edit INDEX TEXT`, `/chat remove INDEX`,
`/chat undo [INDEX]`, `/chat trim INDEX`, `/chat compact [FOCUS]`, and `/chat
clear`. Positive message indexes are 1-based; negative indexes count back from
the end, so `-1` selects the last message. Compaction accepts optional guidance
describing the information the summary should prioritize. Trimming keeps
messages through the selected index and removes newer ones; linked tool-call
transactions are kept structurally valid when removing or trimming messages.

`/prompts` lists the reusable system prompts and their agent associations, plus
the compact prompt. `/prompt` shows the active agent's system prompt and
`/prompt NAME` associates another named system prompt with that agent. `/edit
prompt [NAME]` edits or creates a named system prompt; with no name it edits the
active agent's prompt. `/edit NAME` is a shortcut for an existing named prompt.
Agents store the association in `systemPrompt`, while older inline
`instructions` are migrated to a same-named prompt automatically.

`/edit compact` opens the chat-compaction template. Prompts are saved under
`prompts` in the active configuration (normally `~/.config/pmai/config.json`).
The compact template must contain `{{transcript}}`. `{{focus}}` is replaced with
guidance passed to `/chat compact FOCUS`; if omitted, the focus is appended.
Clearing the compact template restores its built-in default.

Start `pmai` with `-y` (or `--yolo`) to permit all tool calls without approval
prompts for that process. This is the startup equivalent of `/set yolo on`.

The REPL accepts heredoc-style multiline messages. Enter `<<WORD`, type the
message verbatim, then put `WORD` alone on its own line. The delimiter can be
any non-whitespace word; heredoc content is always sent as a message rather
than interpreted as a slash command:

```text
pmai> <<EOF
Explain this code:
if (ready) {
  run();
}
EOF
```

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
selected with `kind: "vision"` on Apple platforms. The same plugin registers
`kind: "tesseract"`, which spawns a locally installed `tesseract` binary, so
OCR also works on Linux when the `tesseract-ocr` package is present. The CLI
picks the configured `ocrProviders` entry, then whatever the platform offers;
when nothing is usable it still starts and reports the reason the first time
`/image ocr` runs. A `tesseract` entry accepts `command` (defaults to
`tesseract`, or `TESSERACT_COMMAND`) and `languages` (for example `eng+spa`,
or `TESSERACT_LANGUAGES`) in its `options`. Other hosts can omit that module or
provide a different OCR implementation without coupling it to their chat/model
provider; PocketMai does this to preserve its layout-aware Markdown OCR.

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

Chats belong to a project, the directory pmai was started in, mirroring the
chat folders PocketMai keeps with a name, a tint, and a working folder. The
project's own file and its chats live in `.pmai/` inside that directory (one
JSON file per chat under `.pmai/chats/`, so add `.pmai/` to your gitignore),
while the list of every project ever opened lives outside them in
`~/.pmai/projects.json` next to the shared `~/.pmai/history.json`. `PMAI_HOME`
or `--home` relocate that root, `PMAI_STATE` or `--state DIR` relocate one
project's chat directory, and `--projects` prints the project list without
starting the REPL. A directory that cannot be written keeps its files under
`~/.pmai/projects/<id>/` instead. `/project` shows the open project,
`/project list` shows them all, `/project name` and `/project tint` set the
name and the prompt color, and `/project forget` drops an entry from the
list. When the default home is in use, chats found in the pre-project
`~/.config/pmai/chats.json` are imported into the first project opened
afterwards and the file is renamed `chats.json.imported`.

The persistence rules are shared with the PocketMai app through MaiCore.
`ChatFileStore` keeps one JSON file per chat in a directory, the layout
PocketMai has used since its first release, with ISO 8601 dates, `.json.corrupt`
quarantine names, and newest-wins merging; PocketMai stores its own
`Conversation` documents through it unchanged, and `AgentChatStore` is the
same store for MaiCore's `AgentChat`. Every launch opens a fresh chat that is
named after its first message, a chat that never receives a message, name, or
archive flag is disposable, and a disposable chat is never written or listed,
whichever way the process ends. Saving never deletes an existing file, so
upgrading a store cannot lose a chat. `AgentProject`, `AgentProjectIndex`, and
`AgentHome` carry the project side, with `AgentProjectTint` stored the way
PocketMai folder colors always were.
`--resume` reopens the most recently updated chat instead. `/chat list`
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

On a terminal the prompt never goes away: the bottom two rows are reserved for
a status line (project, agent, what is running, how much is queued) and the
input line, and everything else scrolls above them. A message typed while a
turn runs is queued and joins the conversation at the agent's next model turn —
after the tool results it is about to read — so a running agent can be steered
without stopping it. `/queue` lists what is waiting, `/queue push TEXT` adds
without sending, `/queue pop` drops the newest, and `/queue flush` drops all.
`@PID TEXT` sends one message to a running child agent, and `/agents focus PID`
sends everything typed to it until `/agents focus main`. When a tool asks for
approval the question is printed above the prompt and answered with `y`, `a`,
`n`, `e`, or `c` at the same prompt; any other line stays an ordinary message
and the question keeps waiting. Piped input keeps the one-line-at-a-time REPL,
where a turn finishes before the next line is read. A line starting with `!`
runs in the system shell with the terminal handed over — `!ls`, `!git diff`,
`!vim notes.md` — so interactive programs work; nothing is captured or sent to
the model, and a non-zero exit status is noted.

Child agents print as they work, in blocks rather than character by character,
every line prefixed with the child's pid (`agent#3 │ …`, `agent#3 → tool …`,
`agent#3 ↲ done …`) so two children working at once stay apart. `ui.subagents`
picks how much: `all` (replies and tool calls), `tools` (tool calls only),
`stats` (one line per model turn), or `none`. `/agents tree` ends with a
`Total:` row summing the turns, tools, and tokens of the whole tree.

On piped input each prompt is preceded by a colored separator so prompts remain
easy to find in terminal scrollback. Long input scrolls horizontally and is
printed in full when submitted. `/set ui.` lists the persisted terminal styling
options; `ui.bgline` colors the status line (or the separator), `ui.fgprompt`,
`ui.bgprompt`, `ui.fgcolor`, `ui.bgcolor`, and `ui.fgtoolresult` accept named
ANSI colors, `rgb:RGB`, or `none`, while `ui.bold` and `ui.markdown` accept `on`
or `off`. `ui.toolResultLines` accepts `all` or a line count (the default is
`all`; `0` restores the compact status-only display).
Successful tool results are yellow by default, tool starts remain green, and
failed results are red. Unified diff removals and additions, including output
from `files_patch`, use dark red and dark green backgrounds. `/set limits.`
shows the per-run limits of the current
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
Up/Down or `Ctrl+P`/`Ctrl+N` move through input history. `Ctrl+R` starts an
incremental reverse search; type to narrow it, press `Ctrl+R` again for an older
match, Return to submit it, or `Ctrl+G` to restore the original input. `Ctrl+A`
and `Ctrl+E` move to the beginning and end, `Ctrl+B` and `Ctrl+F` move one
character left and right like the arrow keys, `Ctrl+W` deletes the previous word,
and `Ctrl+C` cancels the active model or tool run without leaving the REPL.
`Ctrl+Z` suspends pmai with the terminal restored; run `fg` in the shell to
resume the same input or active run.

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
`MaiStandardToolsPlugin` provides `echo`, date/time, the `calc` calculator,
network, and workspace-scoped Files tools.

### ACP and MCP

pmai speaks the Agent Client Protocol both ways and serves MCP too. `pmai --acp`
exposes the selected agent to any ACP editor (Zed, JetBrains, …) over stdio;
`pmai --mcp` exposes it as a single MCP tool. Diagnostics go to stderr so the
JSON-RPC stream stays clean.

The other direction treats a remote ACP agent as an ordinary MaiCore provider:
an `AgentDefinition` whose provider is `kind: "acp"` is selectable, spawnable,
and delegable like any other agent. `/agent acp list` shows the builtin catalog
(gemini, qwen, opencode, goose natively; claude and codex through adapters) with
what is installed, and `/agent acp add NAME [COMMAND ARG ...]` registers one. See
`doc/acp.md` for the design.

### Memory

Durable notes about the person an agent works with — stable facts, standing
preferences, habits worth carrying between chats. pmai keeps one per project in
`.pmai/memory.md`; PocketMai keeps one in its settings. The text, the envelope
it is injected in, the prompt that extends it, and the tools that read other
chats all live in `AgentMemory.swift`, so both hosts behave the same.

The notes are added to the system prompt of top-level runs only, wrapped in an
envelope that says they are inferred, may be stale, and always lose to what the
person is saying now. A subagent grepping a file never sees them, and nothing is
written into the stored transcript: memory is run-scoped context.

```
/memory                      show the notes and how they are configured
/memory edit                 edit them in $EDITOR (same as /edit memory)
/memory learn [FOCUS]        fold this chat into the notes
/memory learn --all [FOCUS]  fold every chat in this project into them
/memory add|set TEXT         append one note, or replace them all
/memory clear                forget everything
/memory reload               re-read the file after editing it elsewhere
/memory on|off               whether the notes reach the model
/memory scope none|project|all   chats the chats_* tools may read
/edit memory-prompt          edit the template /memory learn uses
```

Learning is a merge, not a rewrite: the existing notes travel with the request
and the model returns the complete set, so `/memory learn` never silently
forgets. `prompts.memory` overrides the template (`{{transcript}}` is required;
`{{memory}}` and `{{focus}}` are optional).

`chats_list`, `chats_search`, `chats_read`, and `chats_read_document` let an
agent use other chats as a source of information. `memory.scope` bounds them:
`none` keeps other chats private, `project` allows this project's, and `all`
crosses working directories. Enable them for an agent with `/tools enable
chats`; each call asks for approval.

### Todo list

A task list the agent plans with and ticks off as it works, and that the
person can read and edit. pmai keeps one per project in `.pmai/todo.md` as a
Markdown task list (`- [ ] pending`, `- [x] done`); PocketMai keeps one in its
Todo tool settings. The item, the Markdown form, and the tools live in
`AgentTodo.swift`, so both hosts behave the same.

`todo_list` shows the numbered list, `todo_add` appends pending items (one per
line adds several at once), and `todo_done` ticks one off by its number or a
title fragment. The list persists across chats, and every call reads the file
afresh, so editing it by hand is fine. The tools run without asking for
approval; they are part of the default agent's tool set, and `/tools enable
todo` adds them to another.

```
/todo                      show the list, numbered
/todo add TEXT             append one pending item
/todo done NUMBER|TEXT     mark an item done
/todo edit                 edit the list in $EDITOR
/todo clear                remove every item
/todo path                 print where the file lives
```

### Agents and subagents

An agent definition is a saved setup — provider, model, system prompt, tool set,
and limits — that people switch between with `/agent use ID`. Each one carries a
`description` saying what it is for, which a delegating model also reads when it
picks an agent for a task, and an `enabled` flag that parks a setup without
deleting it. `/agents` lists them; `/agents describe ID TEXT` and
`/agents enable|disable ID` maintain them. Visual mode edits the same fields on
its Agents tab.

A running instance of a definition is a process with a **pid**. `/agents tree`
draws them, `/agents log PID` prints one agent's own transcript, and
`/agents kill PID` stops it and everything under it. Any agent that is allowed
subagents can start more, so the result is a tree, bounded by
`limits.maxSubagentDepth` and `limits.maxSubagents` across the whole tree.
A chat is one process for its whole life, so a child started in the background
three turns ago is still addressable by the run that started it. Every process
has an inbox: `AgentSupervisor.post(_:to:)` queues a user message, and the run
appends it to its transcript at its next model turn — emitting
`AgentEvent.userMessage` — or goes round once more when it arrives while the
model is answering. Hosts pre-register a chat's process with
`AgentRuntime.allocateProcess(agentID:)` so messages can be queued before the
first turn, and read a child's events (tagged with the child's pid, background
or not) to show its work.

Subagents are disabled by default: set an agent's `limits.maxSubagents` above
zero. `agent_start` takes a three-part brief — `context`, `task`, and `output` —
plus an optional `agent`, and waits for the answer unless `wait` is false.
`agent_status` lists the caller's children without waiting, `agent_result`
collects a background answer, and `agent_stop` kills a subtree. A caller may
only address pids inside its own subtree. The retired `spawn_agent` and
`agent_launch` names still run but are no longer offered to models.

`toolDelegation` decides where an agent's tools run. `inline` is the default and
unchanged. `subagent` hides the concrete tools and offers only the `agent_*`
family, so every tool call happens one level down in a child whose transcript is
discarded — the chat grows by one answer instead of by a call and a result for
every step. `/set delegation off|subagent` toggles it and persists it on the
agent. With no child definition named, MaiCore derives a `<agent>.worker` that
inherits the parent's provider, model, and tools.

`prompts.delegation` is the template a brief is rendered through (`{{task}}` is
required; `{{context}}`, `{{output}}`, `{{agent}}`, and `{{cwd}}` are optional),
and `prompts.worker` holds the derived worker's instructions. Both fall back to
MaiCore's built-in text and are editable with `/edit delegation` and
`/edit worker`. See `doc/agents.md` for the design behind all of this.

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
