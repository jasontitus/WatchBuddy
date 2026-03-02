import hashlib
import io
import os
import tempfile
import subprocess

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


def ask_gemini(text: str) -> str:
    """Get a concise response from Gemini."""
    response = gemini_client.models.generate_content(
        model=GEMINI_MODEL,
        contents=text,
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
async def chat(file: UploadFile = File(...), api_key: str = Form(...)):
    """
    Full pipeline for trusted users (family/testers).
    Validates the shared access key, then runs STT -> LLM -> TTS.
    """
    if not ACCESS_KEY or api_key != ACCESS_KEY:
        return JSONResponse(status_code=401, content={"error": "Invalid access key"})

    input_bytes = await file.read()
    print(f"[Chat] Received {len(input_bytes)} bytes: {file.filename}")

    wav_bytes = transcode_to_wav(input_bytes)
    print(f"[Transcode] WAV size: {len(wav_bytes)} bytes")

    user_text = transcribe(wav_bytes)
    print(f"[STT] Transcription: {user_text}")

    if not user_text.strip():
        return StreamingResponse(
            io.BytesIO(b""),
            media_type="audio/mpeg",
            status_code=200,
        )

    assistant_text = ask_gemini(user_text)
    print(f"[LLM] Response: {assistant_text}")

    mp3_bytes = synthesize_speech(assistant_text)
    print(f"[TTS] MP3 size: {len(mp3_bytes)} bytes")

    return StreamingResponse(
        io.BytesIO(mp3_bytes),
        media_type="audio/mpeg",
        headers={"Content-Disposition": "attachment; filename=response.mp3"},
    )


@app.post("/v1/stt")
async def stt(file: UploadFile = File(...)):
    """Speech-to-text only. No auth required (BYOK mode)."""
    input_bytes = await file.read()
    print(f"[STT] Received {len(input_bytes)} bytes: {file.filename}")

    wav_bytes = transcode_to_wav(input_bytes)
    user_text = transcribe(wav_bytes)
    print(f"[STT] Transcription: {user_text}")

    return {"text": user_text}


@app.post("/v1/tts")
async def tts(req: TTSRequest):
    """Text-to-speech only. No auth required (BYOK mode)."""
    print(f"[TTS] Synthesizing: {req.text[:80]}...")

    mp3_bytes = synthesize_speech(req.text)
    print(f"[TTS] MP3 size: {len(mp3_bytes)} bytes")

    return StreamingResponse(
        io.BytesIO(mp3_bytes),
        media_type="audio/mpeg",
        headers={"Content-Disposition": "attachment; filename=response.mp3"},
    )


@app.get("/health")
async def health():
    return {"status": "ok", "access_key_hash": ACCESS_KEY_HASH}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8000")),
        reload=True,
    )
