# aitest — agentic-loop debugger

Standalone macOS executable that mirrors the agentic-loop logic used inside
the MAIChat iOS app, so you can iterate on tool-calling against any
OpenAI-compatible endpoint + MCP servers without rebuilding/running the iOS
app.

## Build

```bash
cd src/ui/ios/aitest
swift build
```

## Run

```bash
swift run aitest \
  --base-url https://api.openai.com/v1 \
  --api-key sk-... \
  --model gpt-4.1-mini \
  --message "list functions in /tmp/binary"
```

### With MCP

```bash
swift run aitest \
  --base-url https://ollama.com/v1 \
  --api-key sk-ollama-... \
  --model gpt-oss:120b \
  --mcp http://192.168.1.10:8080/mcp \
  --mcp-key http://192.168.1.10:8080/mcp=BEARER \
  --message "open /tmp/lib.so and list its symbols" \
  --mode text
```

### Native tool-calling

```bash
swift run aitest \
  --base-url https://api.openai.com/v1 \
  --api-key sk-... \
  --model gpt-4.1 \
  --mcp http://localhost:3000/mcp \
  --mode native \
  --message "..."
```

## What it logs

- MCP discovery (`tools/list`) — number of tools and their names.
- Each iteration:
  - Outgoing request URL + body (truncated).
  - Streamed token output as it arrives (when `--stream`).
  - Number of `<tool_call>` blocks parsed.
  - Tool dispatch + results.
- Final assembled assistant turn.

## Flags

| Flag | Description |
|------|-------------|
| `--base-url URL` | OpenAI-compatible base, e.g. `https://api.openai.com/v1` |
| `--api-key KEY` | Bearer token (or `none`) |
| `--model NAME` | Model identifier |
| `--message TEXT`, `-m` | User prompt |
| `--mode text\|native\|api` | Tool-calling protocol (default `text`; `api` is an alias for `native`) |
| `--no-stream` | Disable streaming |
| `--max-iter N` | Max agent iterations (default 6) |
| `--mcp URL` | MCP server URL, repeatable |
| `--mcp-key URL=KEY` | Bearer for that MCP, repeatable |
| `--system TEXT` | Override system prompt |
| `--quiet` | Suppress per-iteration verbose output |
