import hashlib
import io
import json
import logging
import os
import tempfile
import subprocess
import time

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

app = FastAPI(title="WatchAI Voice Server")

# --- Model Initialization ---

whisper_model = WhisperModel("distil-small.en", device="cpu", compute_type="int8")

gemini_client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
GEMINI_MODEL = "gemini-2.0-flash"
GEMINI_CONFIG = types.GenerateContentConfig(
    system_instruction="You are a helpful voice assistant on an Apple Watch. Be concise. Reply in 1-2 short sentences. Never use markdown or special formatting.",
)

kokoro_pipeline = KPipeline(lang_code="a")

SYSTEM_SAMPLE_RATE = 24000

ACCESS_KEY = os.getenv("ACCESS_KEY", "")
ACCESS_KEY_HASH = hashlib.sha256(ACCESS_KEY.encode()).hexdigest() if ACCESS_KEY else ""


class TTSRequest(BaseModel):
    text: str


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
            timeout=10,
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
        segments, _ = whisper_model.transcribe(tmp_path, beam_size=1)
        text = " ".join(seg.text.strip() for seg in segments)
        return text
    finally:
        os.unlink(tmp_path)


def ask_gemini(text: str, history: list = None) -> str:
    """Get a concise response from Gemini, optionally with conversation history."""
    contents = []
    if history:
        for msg in history:
            role = "model" if msg.get("role") == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": msg["content"]}]})
    contents.append({"role": "user", "parts": [{"text": text}]})

    response = gemini_client.models.generate_content(
        model=GEMINI_MODEL,
        contents=contents,
        config=GEMINI_CONFIG,
    )
    return response.text.strip()


def synthesize_speech(text: str) -> bytes:
    """Generate speech audio using Kokoro TTS, return MP3 bytes."""
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
        timeout=10,
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
    if not ACCESS_KEY or api_key != ACCESS_KEY:
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})

    try:
        input_bytes = await file.read()
        if not input_bytes:
            return JSONResponse(status_code=400, content={"error": "Empty audio file"})
        if len(input_bytes) > MAX_UPLOAD_BYTES:
            return JSONResponse(status_code=400, content={"error": f"File too large ({len(input_bytes)} bytes). Max {MAX_UPLOAD_BYTES} bytes."})
        logger.info(f"[Chat] Received {len(input_bytes)} bytes: {file.filename}")

        # Parse conversation history if provided
        history = None
        if context:
            try:
                history = json.loads(context)
                logger.info(f"[Chat] Conversation history: {len(history)} messages")
            except json.JSONDecodeError:
                logger.warning("[Chat] Invalid context JSON, ignoring")

        t0 = time.time()
        wav_bytes = transcode_to_wav(input_bytes)
        logger.info(f"[Transcode] WAV size: {len(wav_bytes)} bytes ({time.time() - t0:.2f}s)")

        t0 = time.time()
        user_text = transcribe(wav_bytes)
        logger.info(f"[STT] Transcribed {len(user_text.split())} words ({time.time() - t0:.2f}s)")

        if not user_text.strip():
            return StreamingResponse(
                io.BytesIO(b""),
                media_type="audio/mpeg",
                status_code=200,
            )

        t0 = time.time()
        assistant_text = ask_gemini(user_text, history=history)
        logger.info(f"[LLM] Response {len(assistant_text)} chars ({time.time() - t0:.2f}s)")

        t0 = time.time()
        mp3_bytes = synthesize_speech(assistant_text)
        logger.info(f"[TTS] MP3 size: {len(mp3_bytes)} bytes ({time.time() - t0:.2f}s)")

        return StreamingResponse(
            io.BytesIO(mp3_bytes),
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": "attachment; filename=response.mp3",
                "X-Response-Text": assistant_text,
                "X-Question-Text": user_text,
            },
        )
    except Exception as e:
        logger.exception("[Chat] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"Chat pipeline failed: {type(e).__name__}"})


@app.post("/v1/stt")
async def stt(file: UploadFile = File(...)):
    """Speech-to-text only. No auth required (BYOK mode)."""
    try:
        input_bytes = await file.read()
        if not input_bytes:
            return JSONResponse(status_code=400, content={"error": "Empty audio file"})
        if len(input_bytes) > MAX_UPLOAD_BYTES:
            return JSONResponse(status_code=400, content={"error": f"File too large ({len(input_bytes)} bytes). Max {MAX_UPLOAD_BYTES} bytes."})
        logger.info(f"[STT] Received {len(input_bytes)} bytes: {file.filename}")

        t0 = time.time()
        wav_bytes = transcode_to_wav(input_bytes)
        logger.info(f"[Transcode] WAV size: {len(wav_bytes)} bytes ({time.time() - t0:.2f}s)")

        t0 = time.time()
        user_text = transcribe(wav_bytes)
        logger.info(f"[STT] Transcribed {len(user_text.split())} words ({time.time() - t0:.2f}s)")

        return {"text": user_text}
    except Exception as e:
        logger.exception("[STT] Pipeline failed")
        return JSONResponse(status_code=500, content={"error": f"STT failed: {type(e).__name__}"})


@app.post("/v1/tts")
async def tts(req: TTSRequest):
    """Text-to-speech only. No auth required (BYOK mode)."""
    try:
        logger.info(f"[TTS] Synthesizing {len(req.text)} chars...")

        t0 = time.time()
        mp3_bytes = synthesize_speech(req.text)
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
