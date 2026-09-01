<p align="center">
  <img src="mai-logo.png" alt="MAI logo" width="300" />
</p>

# PocketMai

[![CI](https://github.com/trufae/pocketmai/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/pocketmai/actions/workflows/ci.yml)

A native iOS chat client for talking to LLMs — Apple's on-device Foundation Models and any OpenAI-compatible HTTP endpoint.

This app, comes after [MAI](https://github.com/trufae/mai), a cli agent with focus on batch/prompt/cli workflows that also integrates well with VIM editor.

## Features

- **Providers**: Apple Intelligence (on-device) and any OpenAI-compatible API (OpenAI, Ollama, llama.cpp, vLLM, OpenRouter, ...).
- **Tools**: datetime, location, weather, web search, todo, text-to-speech, files, memory — invokable by the model via native tool-calling or a text-protocol fallback.
- **MCP**: configure remote MCP servers and surface them to the model.
- **Multiple system prompts**, persistent conversations, export to Markdown / plain text / JSON / ePUB / Word (docx).
- **Attachments**: text, Markdown, Word (docx) and PDF files. Word and PDF are converted to Markdown on device (PDFs can also be attached as one image per page, and scanned pages are read with Vision OCR).

## Build

Requires Xcode 26+ and an iOS 18+ deployment target. iOS 26-only features
such as Apple Foundation Models, Native iOS Live speech transcription, and
Liquid Glass controls fall back or report unavailable at runtime on older OS
versions.

```sh
make build               # builds for the iOS Simulator without code signing
make run                 # installs and launches Xcode's latest signed device build
make fmt                 # swift-format the sources
```

`make run` selects the first connected iOS device and uses the latest signed
`Debug` device app in Xcode's Derived Data. Use `make run DEVICE=<UDID>` to
select a specific device, or `make run APP_BUNDLE=<path>` to select an app
bundle. Build in Xcode first after source changes; this preserves Xcode's
private-key access for code signing. Open `PocketMai.xcodeproj` when you need
debugger attachment or to run in the Simulator.

## Releases

Ready to use from the [AppStore](https://apps.apple.com/es/app/pocketmai/id6764296742)

But you may find the ipa and source zips in the [Release](https://github.com/trufae/pocketmai/releases) page.

—pancake
