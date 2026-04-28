<p align="center">
  <img src="PocketMai/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="PocketMai logo" width="180" />
</p>

# PocketMai

A native iOS chat client for talking to LLMs — Apple's on-device Foundation Models and any OpenAI-compatible HTTP endpoint.

This app is inspired in the [MAI](https://github.com/trufae/mai) which is a Go agent tool with focus on batch/prompt/cli usecases and also integrates well with VIM.

## Features

- **Providers**: Apple Intelligence (on-device) and any OpenAI-compatible API (OpenAI, Ollama, llama.cpp, vLLM, OpenRouter, ...).
- **Tools**: datetime, location, weather, web search, todo, text-to-speech, files, memory — invokable by the model via native tool-calling or a text-protocol fallback.
- **MCP**: configure remote MCP servers and surface them to the model.
- **Multiple system prompts**, persistent conversations, export to Markdown / plain text / JSON.

## Build

Requires Xcode 16+ and an iOS 18+ deployment target (Foundation Models).

```sh
make build               # builds for the iOS Simulator without code signing
make fmt                 # swift-format the sources
```

Open `PocketMai.xcodeproj` in Xcode to run on a device or simulator.

## Layout

- `PocketMai/` — the iOS app (SwiftUI views, stores, provider + tool services).
- `Shared/` — cross-target types (used by `aitest`).
- `aitest/` — Swift Package CLI mirroring the same agentic protocol for headless debugging.
