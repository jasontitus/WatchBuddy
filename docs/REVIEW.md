# WatchBuddy — Reliability / Performance / Accuracy Review

This document captures findings from a deep review and tracks the fixes applied
on branch `claude/project-review-improvements`.

## Summary

WatchBuddy is a standalone Apple Watch voice assistant backed by a FastAPI
server that runs STT (faster-whisper) → LLM (Gemini) → TTS (Kokoro). It supports
a "trusted" full-pipeline mode and a BYOK split-pipeline mode where the user's
LLM key never touches the server.

The architecture is sound. The most impactful issues are on the server, where
blocking ML work runs on the asyncio event loop, models are shared across
threads without synchronization, and a few error paths can crash a request.

## Findings & fixes

### Server (high impact)

| # | Area | Issue | Fix |
|---|------|-------|-----|
| S1 | Performance / reliability | `async def` endpoints call blocking work (ffmpeg, Whisper, Kokoro) directly on the event loop, serializing all requests and blocking `/health`. | Offload every blocking call with `asyncio.to_thread(...)`. |
| S2 | Reliability | Whisper and Kokoro models are shared mutable state; FastAPI threadpool can call them concurrently → corruption / crashes (CTranslate2 / torch are not reentrant). | Guard each model with its own `threading.Lock`. |
| S3 | Security | Access-key check used `!=`, which is not constant-time. | Compare with `hmac.compare_digest`. |
| S4 | Reliability | `ask_gemini` did `response.text.strip()`; Gemini returns `text=None` when a response is blocked/empty → `AttributeError` → 500. | Guard for `None`/empty and return a safe fallback. |
| S5 | Reliability | Conversation `history` was trusted blindly; a malformed entry (missing `content`, not a list) raised `KeyError`/`TypeError` → 500. | Validate and coerce history into well-formed turns; drop bad entries. |
| S6 | Accuracy | Whisper ran without a VAD filter, so silence/breath was transcribed as hallucinated words ("Thank you.", "you", etc.). | Enable `vad_filter=True` and `condition_on_previous_text=False`. |
| S7 | Reliability | TTS accepted empty/whitespace text and tried to synthesize, producing a hard 500 ("TTS produced no audio"). | Reject empty text with a clear 400. |
| S8 | Reliability | Unbounded `history` could be sent to the LLM, growing latency/cost without limit. | Cap server-side history to the most recent N turns. |
| S9 | Operability | Missing `GOOGLE_API_KEY` / `ACCESS_KEY` only surfaced as a 500 mid-request. | Log explicit warnings at startup. |
| S10 | Performance | ffmpeg timeouts were a hard 10s; long TTS on CPU can exceed it. | Make timeouts configurable via env (`FFMPEG_TIMEOUT`). |
| S11 | Accuracy | Raw LLM/transcript text was placed in HTTP headers; non-Latin-1 characters (em-dash, accents, emoji) get mangled, so the displayed text was garbled. | Percent-encode header values on the server, percent-decode on the watch. |
| S12 | Reliability | Trusted-mode Gemini call ran once; a transient network blip/5xx failed the whole request (BYOK path already retried). | Retry transient LLM failures once with a short backoff. |

### Watch app (review-level — not compiled here)

| # | Area | Issue | Fix |
|---|------|-------|-----|
| W1 | Reliability | Empty/near-silent recording → server returns empty 200 body → watch writes a 0-byte mp3 and AVAudioPlayer throws a confusing "Playback error". | Detect empty audio in `fullPipeline` and surface the friendly "Could not understand audio" message. |
| W2 | Performance / cost | `conversationHistory` grows without bound across "continue" turns and is re-sent every request. | Cap to the last N turns on the client too. |
| W3 | Reliability | A stop tapped immediately after record yields a tiny/empty file that still round-trips to the server. | (Documented; server now returns the friendly empty-transcription path.) |

> **Note on targets:** the repo contains **two** Swift apps, and both ship to
> users: the standalone watch app (`WatchAIWatch Watch App/`) and a full iOS
> companion app (`WatchAI/`) with its own chat UI and a duplicate copy of the
> manager classes. (The README describes `WatchAI/` as a placeholder, which is
> stale — it's a working app.) Because both call `/v1/chat` and read the
> `X-Response-Text`/`X-Question-Text` headers, the W1 (empty-audio) and S11
> (percent-decode) fixes were applied to **both** `NetworkManager.swift` copies,
> and the W2 history cap to both `ContentView.swift` files. Any future change to
> the shared networking/audio logic must be mirrored across both targets (or
> the duplication factored into a shared target).

## Testing

Server changes are covered by `Server/test_main.py` (extended). Run:

```
cd Server && python -m pytest test_main.py -q
```
</content>
