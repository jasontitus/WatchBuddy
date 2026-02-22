# WatchBuddy

A standalone Apple Watch voice assistant. Tap the mic, ask a question, and hear the AI respond — all from your wrist.

## Architecture

The watch app supports two modes:

### Trusted Mode (Server does everything)
A single round trip. The watch sends audio to the server, which handles STT → LLM → TTS and returns MP3 audio. The server uses its own API key. Users authenticate with a shared access key set in the server's `.env` file.

```
Watch --[audio + access key]--> Server (STT → LLM → TTS) --[mp3]--> Watch
```

### BYOK Mode (Bring Your Own Key)
Three round trips. The user's API key never touches the server — it goes directly from the watch to the LLM provider.

```
Watch --[audio]--> Server (STT) --[text]--> Watch
Watch --[text + API key]--> LLM Provider --[text]--> Watch
Watch --[text]--> Server (TTS) --[mp3]--> Watch
```

Supported LLM providers in BYOK mode: Gemini, OpenAI, Anthropic.

## Project Structure

```
WatchAI/                          # iOS companion app (required wrapper for App Store)
  WatchAIApp.swift                # App entry point
  ContentView.swift               # Placeholder UI directing users to the watch

WatchAIWatch Watch App/           # Standalone watchOS app
  WatchAIWatchApp.swift           # App entry point
  ContentView.swift               # Main UI — mic, stop, play buttons
  SettingsView.swift              # Server URL, mode toggle, provider picker, API key
  Managers/
    NetworkManager.swift          # Dual-path networking (trusted vs BYOK)
    AudioRecorderManager.swift    # M4A recording via AVAudioRecorder
    AudioPlayerManager.swift      # MP3 playback via AVPlayer
    SessionManager.swift          # WKExtendedRuntimeSession for background audio
    KeychainManager.swift         # Secure API key storage

docs/                             # GitHub Pages
  index.html                      # Support page
  privacy.html                    # Privacy policy
```

## Server

The companion server lives in a separate directory. See [Server/README](../watchbuddy/WatchBuddy/Server/) or set up your own with these endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `POST /v1/chat` | multipart | Full pipeline (trusted mode). Requires `api_key` form field. Returns MP3. |
| `POST /v1/stt` | multipart | Speech-to-text only. Returns `{"text": "..."}`. |
| `POST /v1/tts` | JSON | Text-to-speech only. Accepts `{"text": "..."}`. Returns MP3. |
| `GET /health` | — | Health check. |

## Setup

1. Open `WatchAI.xcodeproj` in Xcode
2. Set your team and bundle identifiers
3. Build and run the `WatchAIWatch Watch App` scheme on your Apple Watch
4. In the watch app, tap the gear icon to configure:
   - **Server URL**: Your server's address (e.g., `https://myserver.example.com`)
   - **Mode**: Toggle "Use Server's AI" for trusted mode, or leave off for BYOK
   - **API Key**: Paste your access key (trusted mode) or LLM API key (BYOK mode)

## Requirements

- Xcode 26+
- watchOS 26+
- A running server instance with STT/TTS capabilities
