import asyncio
import hashlib
import hmac
import io
import json
import logging
import os
import tempfile
import threading
import subprocess
import time
from urllib.parse import quote

import numpy as np
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from faster_whisper import WhisperModel
from google import genai
from google.genai import types
from kokoro import KPipeline

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("watchai")

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB
MAX_HISTORY_TURNS = 10  # cap conversation context sent to the LLM
MAX_TTS_CHARS = 2000  # guard against runaway synthesis
MAX_TEXT_CHARS = 4000  # cap /v1/text input sent to the LLM
MAX_HISTORY_MSG_CHARS = 2000  # cap each history message sent to the LLM
# Reject request bodies larger than the upload cap plus multipart/JSON overhead,
# before the framework buffers them to disk/RAM.
MAX_BODY_BYTES = MAX_UPLOAD_BYTES + 1024 * 1024
FFMPEG_TIMEOUT = int(os.getenv("FFMPEG_TIMEOUT", "30"))
LLM_MAX_ATTEMPTS = 2  # retry transient Gemini failures once

DEVICE = os.getenv("DEVICE", "cpu")
COMPUTE_TYPE = "float16" if DEVICE == "cuda" else "int8"

app = FastAPI(title="WatchAI Voice Server")

# --- Model Initialization ---

whisper_model = WhisperModel("distil-small.en", device=DEVICE, compute_type=COMPUTE_TYPE)

# faster-whisper (CTranslate2) and Kokoro (torch) models are not safe to call
# from multiple threads at once. FastAPI offloads blocking work to a threadpool,
# so guard each model with its own lock to serialize inference per model while
# still allowing STT and TTS to run concurrently.
_whisper_lock = threading.Lock()
_kokoro_lock = threading.Lock()

gemini_client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.6-flash")
GEMINI_CONFIG = types.GenerateContentConfig(
    system_instruction="You are a helpful voice assistant on an Apple Watch. Be concise. Reply in 1-2 short sentences. Never use markdown or special formatting.",
    # gemini-3.6-flash rejects thinking_budget=0 (INVALID_ARGUMENT); 128 is the
    # lowest accepted budget and keeps latency close to no-thinking.
    thinking_config=types.ThinkingConfig(thinking_budget=128),
)

kokoro_pipeline = KPipeline(lang_code="a")

SYSTEM_SAMPLE_RATE = 24000

ACCESS_KEY = os.getenv("ACCESS_KEY", "")
ACCESS_KEY_HASH = hashlib.sha256(ACCESS_KEY.encode()).hexdigest() if ACCESS_KEY else ""

# /v1/stt and /v1/tts ship unauthenticated for BYOK clients. Set
# REQUIRE_AUTH_STT_TTS=1 to demand the access key on them too (breaks BYOK
# voice mode on clients that don't send it).
REQUIRE_AUTH_STT_TTS = os.getenv("REQUIRE_AUTH_STT_TTS", "0").lower() in ("1", "true", "yes")

if not ACCESS_KEY:
    logger.warning("ACCESS_KEY is not set — trusted-mode endpoints (/v1/chat, /v1/text) will reject all requests.")
if not os.getenv("GOOGLE_API_KEY"):
    logger.warning("GOOGLE_API_KEY is not set — LLM calls will fail.")


def verify_access_key(provided: str) -> bool:
    """Constant-time comparison of the provided access key against the server's."""
    if not ACCESS_KEY or not provided:
        return False
    return hmac.compare_digest(provided, ACCESS_KEY)


@app.middleware("http")
async def limit_body_size(request, call_next):
    """Reject oversized requests up front, before multipart parsing buffers them."""
    content_length = request.headers.get("content-length")
    if content_length and content_length.isdigit() and int(content_length) > MAX_BODY_BYTES:
        return JSONResponse(status_code=413, content={"error": "Request body too large"})
    return await call_next(request)


async def read_upload_capped(file: UploadFile) -> bytes | None:
    """Read an upload in chunks, returning None once it exceeds MAX_UPLOAD_BYTES.

    Avoids buffering the whole (attacker-controlled) body into memory before
    the size check.
    """
    chunks = []
    total = 0
    while chunk := await file.read(256 * 1024):
        total += len(chunk)
        if total > MAX_UPLOAD_BYTES:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


def parse_history(context: str) -> list | None:
    """Parse and validate conversation history JSON.

    Returns a list of {"role", "content"} dicts (most recent MAX_HISTORY_TURNS*2
    messages), or None if absent/invalid. Malformed entries are dropped rather
    than crashing the request.
    """
    if not context:
        return None
    try:
        raw = json.loads(context)
    except (json.JSONDecodeError, TypeError):
        logger.warning("Invalid context JSON, ignoring")
        return None
    if not isinstance(raw, list):
        logger.warning("Context is not a list, ignoring")
        return None

    cleaned = []
    for msg in raw:
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        role = "assistant" if msg.get("role") == "assistant" else "user"
        cleaned.append({"role": role, "content": content[:MAX_HISTORY_MSG_CHARS]})

    if not cleaned:
        return None
    # Keep only the most recent turns to bound latency/cost.
    return cleaned[-(MAX_HISTORY_TURNS * 2):]


class TTSRequest(BaseModel):
    text: str
    api_key: str = ""  # only checked when REQUIRE_AUTH_STT_TTS is set


class TextChatRequest(BaseModel):
    text: str
    api_key: str
    context: str = ""


def transcode_to_wav(input_bytes: bytes) -> bytes:
    """Convert uploaded M4A to 16kHz mono WAV using ffmpeg subprocess."""
    with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as tmp_in:
        tmp_in.write(input_bytes)
        tmp_in_path = tmp_in.name

    try:
        result = subprocess.run(
            [
                "ffmpeg", "-y", "-i", tmp_in_path,
                "-ar", "16000", "-ac", "1", "-f", "wav", "pipe:1",
            ],
            capture_output=True,
            timeout=FFMPEG_TIMEOUT,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg error: {result.stderr.decode()}")
        return result.stdout
    finally:
        os.unlink(tmp_in_path)


def transcribe(wav_bytes: bytes) -> str:
    """Transcribe WAV audio using Faster-Whisper."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(wav_bytes)
        tmp_path = tmp.name

    try:
        # vad_filter drops silence/noise so Whisper doesn't hallucinate filler
        # words ("Thank you.", "you") on quiet or empty recordings.
        # condition_on_previous_text=False avoids repetition loops on short clips.
        with _whisper_lock:
            segments, _ = whisper_model.transcribe(
                tmp_path,
                beam_size=1,
                vad_filter=True,
                condition_on_previous_text=False,
            )
            text = " ".join(seg.text.strip() for seg in segments)
        return text.strip()
    finally:
        os.unlink(tmp_path)


def ask_gemini(text: str, history: list = None) -> str:
    """Get a concise response from Gemini, optionally with conversation history."""
    contents = []
    if history:
        for msg in history:
            content = msg.get("content")
            if not isinstance(content, str) or not content.strip():
                continue
            role = "model" if msg.get("role") == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": content}]})
    contents.append({"role": "user", "parts": [{"text": text}]})

    # Retry transient failures (network blips, 5xx) with a short backoff.
    last_error = None
    for attempt in range(LLM_MAX_ATTEMPTS):
        try:
            response = gemini_client.models.generate_content(
                model=GEMINI_MODEL,
                contents=contents,
                config=GEMINI_CONFIG,
            )
            break
        except Exception as e:  # noqa: BLE001 - retry any transient API error
            last_error = e
            if attempt < LLM_MAX_ATTEMPTS - 1:
                logger.warning(f"[LLM] Attempt {attempt + 1} failed ({type(e).__name__}), retrying...")
                time.sleep(0.5 * (attempt + 1))
    else:
        # All attempts exhausted; propagate so the endpoint returns a 500.
        raise last_error

    # response.text is None when the model returns no/blocked content.
    reply = (response.text or "").strip()
    if not reply:
        logger.warning("[LLM] Empty/blocked response from Gemini")
        return "Sorry, I couldn't come up with a response. Please try again."
    return reply


def synthesize_speech(text: str) -> bytes:
    """Generate speech audio using Kokoro TTS, return MP3 bytes."""
    with _kokoro_lock:
        generator = kokoro_pipeline(text, voice="af_heart", speed=1.1)

        all_audio = []
        for _, _, audio_chunk in generator:
            all_audio.append(audio_chunk)

    if not all_audio:
        raise RuntimeError("TTS produced no audio")

    audio = np.concatenate(all_audio)

    # Normalize and boost volume
    peak = np.abs(audio).max()
    if peak > 0:
        audio = audio / peak * 0.95

    # Convert float32 numpy array to MP3 via ffmpeg
    pcm_bytes = (audio * 32767).astype(np.int16).tobytes()

    result = subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "s16le", "-ar", str(SYSTEM_SAMPLE_RATE), "-ac", "1", "-i", "pipe:0",
            "-codec:a", "libmp3lame", "-b:a", "64k", "-f", "mp3", "pipe:1",
        ],
        input=pcm_bytes,
        capture_output=True,
        timeout=FFMPEG_TIMEOUT,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg MP3 encode error: {result.stderr.decode()}")

    return result.stdout


@app.post("/v1/chat")
async def chat(file: UploadFile = File(...), api_key: str = Form(...), context: str = Form("")):
    """
    Full pipeline for trusted users (family/testers).
    Validates the shared access key, then runs STT -> LLM -> TTS.
    Optional 'context' field: JSON array of [{role, content}] for conversation history.
    """
    if not verify_access_key(api_key):
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})

    try:
        input_bytes = await read_upload_capped(file)
        if input_bytes is None:
            return JSONResponse(status_code=400, content={"error": f"File too large. Max {MAX_UPLOAD_BYTES} bytes."})
        if not input_bytes:
            return JSONResponse(status_code=400, content={"error": "Empty audio file"})
        logger.info(f"[Chat] Received {len(input_bytes)} bytes: {file.filename!r}")

        # Parse conversation history if provided
        history = parse_history(context)
        if history:
            logger.info(f"[Chat] Conversation history: {len(history)} messages")

        t0 = time.time()
        wav_bytes = await asyncio.to_thread(transcode_to_wav, input_bytes)
        logger.info(f"[Transcode] WAV size: {len(wav_bytes)} bytes ({time.time() - t0:.2f}s)")

        t0 = time.time()
        user_text = await asyncio.to_thread(transcribe, wav_bytes)
        logger.info(f"[STT] Transcribed {len(user_text.split())} words ({time.time() - t0:.2f}s)")

        if not user_text.strip():
            return StreamingResponse(
                io.BytesIO(b""),
                media_type="audio/mpeg",
                status_code=200,
            )

        t0 = time.time()
        assistant_text = await asyncio.to_thread(ask_gemini, user_text, history=history)
        logger.info(f"[LLM] Response {len(assistant_text)} chars ({time.time() - t0:.2f}s)")

        t0 = time.time()
        mp3_bytes = await asyncio.to_thread(synthesize_speech, assistant_text)
        logger.info(f"[TTS] MP3 size: {len(mp3_bytes)} bytes ({time.time() - t0:.2f}s)")

        # HTTP headers are limited to Latin-1; arbitrary LLM/transcript text may
        # contain em-dashes, accented letters, or emoji. Percent-encode to keep
        # the values ASCII-safe and lossless (the watch percent-decodes them).
        return StreamingResponse(
            io.BytesIO(mp3_bytes),
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": "attachment; filename=response.mp3",
                "X-Response-Text": quote(assistant_text),
                "X-Question-Text": quote(user_text),
            },
        )
    except Exception as e:
        logger.exception("[Chat] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"Chat pipeline failed: {type(e).__name__}"})


@app.post("/v1/text")
async def text_chat(req: TextChatRequest):
    """
    Text-only chat for trusted users. Validates access key, runs LLM only (no STT/TTS).
    """
    if not verify_access_key(req.api_key):
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})

    try:
        if not req.text.strip():
            return JSONResponse(status_code=400, content={"error": "Empty text"})
        if len(req.text) > MAX_TEXT_CHARS:
            return JSONResponse(status_code=400, content={"error": f"Text too long. Max {MAX_TEXT_CHARS} characters."})
        logger.info(f"[TextChat] Received {len(req.text)} chars")

        history = parse_history(req.context)
        if history:
            logger.info(f"[TextChat] Conversation history: {len(history)} messages")

        t0 = time.time()
        assistant_text = await asyncio.to_thread(ask_gemini, req.text, history=history)
        logger.info(f"[TextChat] Response {len(assistant_text)} chars ({time.time() - t0:.2f}s)")

        return {"response_text": assistant_text}
    except Exception as e:
        logger.exception("[TextChat] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"Text chat failed: {type(e).__name__}"})


@app.post("/v1/stt")
async def stt(file: UploadFile = File(...), api_key: str = Form("")):
    """Speech-to-text only. Auth optional (BYOK mode) unless REQUIRE_AUTH_STT_TTS."""
    if REQUIRE_AUTH_STT_TTS and not verify_access_key(api_key):
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})
    try:
        input_bytes = await read_upload_capped(file)
        if input_bytes is None:
            return JSONResponse(status_code=400, content={"error": f"File too large. Max {MAX_UPLOAD_BYTES} bytes."})
        if not input_bytes:
            return JSONResponse(status_code=400, content={"error": "Empty audio file"})
        logger.info(f"[STT] Received {len(input_bytes)} bytes: {file.filename!r}")

        t0 = time.time()
        wav_bytes = await asyncio.to_thread(transcode_to_wav, input_bytes)
        logger.info(f"[Transcode] WAV size: {len(wav_bytes)} bytes ({time.time() - t0:.2f}s)")

        t0 = time.time()
        user_text = await asyncio.to_thread(transcribe, wav_bytes)
        logger.info(f"[STT] Transcribed {len(user_text.split())} words ({time.time() - t0:.2f}s)")

        return {"text": user_text}
    except Exception as e:
        logger.exception("[STT] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"STT failed: {type(e).__name__}"})


@app.post("/v1/tts")
async def tts(req: TTSRequest):
    """Text-to-speech only. Auth optional (BYOK mode) unless REQUIRE_AUTH_STT_TTS."""
    if REQUIRE_AUTH_STT_TTS and not verify_access_key(req.api_key):
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})
    try:
        if not req.text.strip():
            return JSONResponse(status_code=400, content={"error": "Empty text"})
        text = req.text[:MAX_TTS_CHARS]
        logger.info(f"[TTS] Synthesizing {len(text)} chars...")

        t0 = time.time()
        mp3_bytes = await asyncio.to_thread(synthesize_speech, text)
        logger.info(f"[TTS] MP3 size: {len(mp3_bytes)} bytes ({time.time() - t0:.2f}s)")

        return StreamingResponse(
            io.BytesIO(mp3_bytes),
            media_type="audio/mpeg",
            headers={"Content-Disposition": "attachment; filename=response.mp3"},
        )
    except Exception as e:
        logger.exception("[TTS] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"TTS failed: {type(e).__name__}"})


@app.api_route("/health", methods=["GET", "HEAD"])
async def health():
    return {"status": "ok", "access_key_hash": ACCESS_KEY_HASH}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8000")),
    )
