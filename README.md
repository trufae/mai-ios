<p align="center">
  <img src="mai-logo.png" alt="MAI logo" width="300" />
</p>

# PocketMai

A native iOS chat client for talking to LLMs — Apple's on-device Foundation Models and any OpenAI-compatible HTTP endpoint.

This app is inspired in the [MAI](https://github.com/trufae/mai) which is a Go agent tool with focus on batch/prompt/cli usecases and also integrates well with VIM.

## Features

- **Providers**: Apple Intelligence (on-device) and any OpenAI-compatible API (OpenAI, Ollama, llama.cpp, vLLM, OpenRouter, ...).
- **Tools**: datetime, location, weather, web search, todo, text-to-speech, files, memory — invokable by the model via native tool-calling or a text-protocol fallback.
- **MCP**: configure remote MCP servers and surface them to the model.
- **Multiple system prompts**, persistent conversations, export to Markdown / plain text / JSON / ePUB.

## Build

Requires Xcode 26+ and an iOS 18+ deployment target. iOS 26-only features
such as Apple Foundation Models, Native iOS Live speech transcription, and
Liquid Glass controls fall back or report unavailable at runtime on older OS
versions.

```sh
make build               # builds for the iOS Simulator without code signing
make fmt                 # swift-format the sources
```

Open `PocketMai.xcodeproj` in Xcode to run on a device or simulator.

## Layout

- `PocketMai/` — the iOS app (SwiftUI views, stores, provider + tool services).
- `Shared/` — cross-target types (used by `aitest`).
- `aitest/` — Swift Package CLI mirroring the same agentic protocol for headless debugging.
