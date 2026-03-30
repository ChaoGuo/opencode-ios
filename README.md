# OpenCode iOS

A native iOS client for [OpenCode](https://github.com/sst/opencode) — an AI coding assistant that runs locally on your machine.

## Features

- **Chat interface** — Full conversation UI with markdown and code block rendering
- **Multi-session** — Create and manage multiple chat sessions
- **Real-time streaming** — Server-Sent Events (SSE) for live message streaming
- **Model picker** — Switch between any model/provider configured on your server
- **Voice input** — Hold-to-talk voice recording with automatic transcription
- **Image attachments** — Send images from your photo library
- **iPad support** — NavigationSplitView with sidebar on iPad, stack navigation on iPhone

## Requirements

- iOS 17.0+
- Xcode 15+
- A running [OpenCode](https://github.com/sst/opencode) server (local or remote)

## Getting Started

1. Clone the repo:
   ```bash
   git clone https://github.com/ChaoGuo/opencode-ios.git
   cd opencode-ios
   ```

2. Open in Xcode:
   ```bash
   open OpenCode.xcodeproj
   ```

3. Build and run on a simulator or device.

4. In the app, tap the gear icon and set your **Server URL** (e.g. `http://192.168.1.100:4096`).

## Configuration

All settings are stored in UserDefaults and configured in-app:

| Setting | Description |
|---|---|
| Server URL | Base URL of your OpenCode server |
| Username | Optional HTTP Basic Auth username |
| Password | Optional HTTP Basic Auth password |
| Model | Selected model ID (persisted across sessions) |

## Architecture

| File | Responsibility |
|---|---|
| `AppViewModel.swift` | Central `@Observable` state — sessions, messages, SSE events |
| `APIService.swift` | HTTP client for all REST endpoints |
| `SSEService.swift` | URLSession-based SSE listener with auto-reconnect |
| `AppSettings.swift` | UserDefaults-backed settings store |
| `Models.swift` | Codable data models matching the OpenCode API |
| `ContentView.swift` | Root NavigationSplitView |
| `SessionListView.swift` | Session list with swipe-to-delete |
| `ChatView.swift` | Chat area, input bar, voice/image input |
| `MessageView.swift` | Message rendering: text, code, reasoning, tool calls |
| `ModelPickerView.swift` | Searchable model/provider picker sheet |
| `SettingsView.swift` | Server and auth configuration |

## API

Connects to the OpenCode HTTP/SSE API:

```
GET    /session               List sessions
POST   /session               Create session
DELETE /session/:id           Delete session
GET    /session/:id/message   List messages
POST   /session/:id/prompt_async  Send message (streaming via SSE)
POST   /session/:id/abort     Abort generation
GET    /config/providers      List available models
GET    /global/health         Health check
GET    /event                 SSE event stream
```

## License

MIT
