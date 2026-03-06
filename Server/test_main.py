"""
Unit tests for WatchAI server endpoints.

Mocks all heavy ML dependencies (Whisper, Gemini, Kokoro) to test
endpoint logic: validation, error handling, auth, and success paths.
"""

import sys
from unittest.mock import MagicMock, patch

# Mock heavy ML modules before importing main
_mock_whisper = MagicMock()
_mock_google = MagicMock()
_mock_google_genai = MagicMock()
_mock_google_genai_types = MagicMock()
_mock_kokoro = MagicMock()

sys.modules["faster_whisper"] = _mock_whisper
sys.modules["google"] = _mock_google
sys.modules["google.genai"] = _mock_google_genai
sys.modules["google.genai.types"] = _mock_google_genai_types
sys.modules["kokoro"] = _mock_kokoro

# Set required env vars before importing main
import os

os.environ.setdefault("ACCESS_KEY", "test-secret-key")
os.environ.setdefault("GOOGLE_API_KEY", "fake-key")

import io
import json
import pytest
from fastapi.testclient import TestClient

from main import app, MAX_UPLOAD_BYTES

client = TestClient(app)

VALID_KEY = os.environ["ACCESS_KEY"]
FAKE_AUDIO = b"\x00\x01\x02\x03" * 100  # 400 bytes of fake audio


# ──────────────────────────────────────────────
# GET /health
# ──────────────────────────────────────────────

class TestHealth:
    def test_health_returns_ok(self):
        r = client.get("/health")
        assert r.status_code == 200
        data = r.json()
        assert data["status"] == "ok"
        assert "access_key_hash" in data

    def test_health_hash_is_sha256(self):
        r = client.get("/health")
        h = r.json()["access_key_hash"]
        assert len(h) == 64  # SHA-256 hex digest


# ──────────────────────────────────────────────
# POST /v1/chat
# ──────────────────────────────────────────────

class TestChat:
    def test_chat_bad_key_returns_401(self):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": "wrong-key"},
        )
        assert r.status_code == 401
        assert "error" in r.json()

    def test_chat_empty_file_returns_400(self):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(b""), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 400
        assert "Empty" in r.json()["error"]

    def test_chat_oversized_file_returns_400(self):
        big = b"\x00" * (MAX_UPLOAD_BYTES + 1)
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(big), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 400
        assert "too large" in r.json()["error"]

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Hello there!")
    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_success_returns_audio(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200
        assert r.headers["content-type"] == "audio/mpeg"
        assert r.headers["x-response-text"] == "Hello there!"
        assert len(r.content) > 0

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Hello there!")
    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_success_returns_question_text_header(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200
        assert r.headers["x-question-text"] == "Hi"

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Paris is the capital.")
    @patch("main.transcribe", return_value="What is the capital of France?")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_with_context_passes_history_to_llm(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        context = json.dumps([
            {"role": "user", "content": "Hi there"},
            {"role": "assistant", "content": "Hello! How can I help?"},
        ])
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY, "context": context},
        )
        assert r.status_code == 200
        # Verify ask_gemini was called with history
        mock_llm.assert_called_once()
        call_kwargs = mock_llm.call_args
        assert call_kwargs[1]["history"] is not None
        assert len(call_kwargs[1]["history"]) == 2

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Sure!")
    @patch("main.transcribe", return_value="Tell me more")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_with_empty_context_works(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY, "context": ""},
        )
        assert r.status_code == 200
        mock_llm.assert_called_once()
        assert mock_llm.call_args[1]["history"] is None

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Sure!")
    @patch("main.transcribe", return_value="Tell me more")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_with_invalid_context_json_ignores_it(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY, "context": "not valid json{{{"},
        )
        assert r.status_code == 200
        mock_llm.assert_called_once()
        assert mock_llm.call_args[1]["history"] is None

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Response after multi-turn")
    @patch("main.transcribe", return_value="And what about dessert?")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_with_multi_turn_context(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        context = json.dumps([
            {"role": "user", "content": "What should I eat?"},
            {"role": "assistant", "content": "Try pasta."},
            {"role": "user", "content": "What kind?"},
            {"role": "assistant", "content": "Carbonara is great."},
        ])
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY, "context": context},
        )
        assert r.status_code == 200
        assert r.headers["x-question-text"] == "And what about dessert?"
        assert r.headers["x-response-text"] == "Response after multi-turn"
        call_kwargs = mock_llm.call_args
        assert len(call_kwargs[1]["history"]) == 4

    @patch("main.transcribe", return_value="   ")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_empty_transcription_returns_empty_audio(self, mock_transcode, mock_stt):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200
        assert len(r.content) == 0

    @patch("main.transcode_to_wav", side_effect=RuntimeError("ffmpeg exploded"))
    def test_chat_pipeline_error_returns_500(self, mock_transcode):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 500
        assert "error" in r.json()
        # Error should contain type name, not the raw message (PII safety)
        assert "RuntimeError" in r.json()["error"]

    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    @patch("main.ask_gemini", side_effect=Exception("Gemini API down"))
    def test_chat_gemini_error_returns_500(self, mock_gemini, mock_transcode, mock_stt):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 500
        # Should NOT leak the raw error message, only the type
        assert "Exception" in r.json()["error"]
        assert "Gemini API down" not in r.json()["error"]

    @patch("main.ask_gemini", return_value="Hello!")
    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    @patch("main.synthesize_speech", side_effect=RuntimeError("TTS produced no audio"))
    def test_chat_tts_error_returns_500(self, mock_tts, mock_transcode, mock_stt, mock_llm):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 500
        assert "RuntimeError" in r.json()["error"]


# ──────────────────────────────────────────────
# POST /v1/stt
# ──────────────────────────────────────────────

class TestSTT:
    def test_stt_empty_file_returns_400(self):
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(b""), "audio/mp4")},
        )
        assert r.status_code == 400
        assert "Empty" in r.json()["error"]

    def test_stt_oversized_file_returns_400(self):
        big = b"\x00" * (MAX_UPLOAD_BYTES + 1)
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(big), "audio/mp4")},
        )
        assert r.status_code == 400
        assert "too large" in r.json()["error"]

    @patch("main.transcribe", return_value="Hello world")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_stt_success_returns_text(self, mock_transcode, mock_stt):
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 200
        assert r.json()["text"] == "Hello world"

    @patch("main.transcode_to_wav", side_effect=RuntimeError("ffmpeg not found"))
    def test_stt_pipeline_error_returns_500(self, mock_transcode):
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 500
        assert "error" in r.json()
        assert "STT failed" in r.json()["error"]
        assert "RuntimeError" in r.json()["error"]

    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    @patch("main.transcribe", side_effect=Exception("Whisper crashed"))
    def test_stt_transcribe_error_returns_500(self, mock_stt, mock_transcode):
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 500
        # Should NOT leak raw error message
        assert "Exception" in r.json()["error"]
        assert "Whisper crashed" not in r.json()["error"]


# ──────────────────────────────────────────────
# POST /v1/tts
# ──────────────────────────────────────────────

class TestTTS:
    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    def test_tts_success_returns_audio(self, mock_tts):
        r = client.post("/v1/tts", json={"text": "Hello world"})
        assert r.status_code == 200
        assert r.headers["content-type"] == "audio/mpeg"
        assert len(r.content) > 0

    @patch("main.synthesize_speech", side_effect=RuntimeError("TTS produced no audio"))
    def test_tts_error_returns_500(self, mock_tts):
        r = client.post("/v1/tts", json={"text": "Hello"})
        assert r.status_code == 500
        assert "TTS failed" in r.json()["error"]
        assert "RuntimeError" in r.json()["error"]

    def test_tts_missing_text_returns_422(self):
        r = client.post("/v1/tts", json={})
        assert r.status_code == 422  # Pydantic validation error


# ──────────────────────────────────────────────
# Input validation edge cases
# ──────────────────────────────────────────────

class TestInputValidation:
    def test_chat_missing_file_returns_422(self):
        r = client.post("/v1/chat", data={"api_key": VALID_KEY})
        assert r.status_code == 422

    def test_stt_missing_file_returns_422(self):
        r = client.post("/v1/stt")
        assert r.status_code == 422

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Response")
    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_exactly_at_size_limit_succeeds(self, mock_t, mock_s, mock_g, mock_tts):
        data = b"\x00" * MAX_UPLOAD_BYTES  # exactly at limit
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(data), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200


# ──────────────────────────────────────────────
# PII safety: error responses must not leak user content
# ──────────────────────────────────────────────

class TestPIISafety:
    @patch("main.transcribe", return_value="My SSN is 123-45-6789")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    @patch("main.ask_gemini", side_effect=Exception("failed processing: My SSN is 123-45-6789"))
    def test_chat_error_does_not_leak_user_text(self, mock_gemini, mock_transcode, mock_stt):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 500
        error_msg = r.json()["error"]
        assert "123-45-6789" not in error_msg
        assert "SSN" not in error_msg

    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    @patch("main.transcribe", side_effect=Exception("error with user input: call me at 555-1234"))
    def test_stt_error_does_not_leak_user_text(self, mock_stt, mock_transcode):
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 500
        error_msg = r.json()["error"]
        assert "555-1234" not in error_msg

    @patch("main.synthesize_speech", side_effect=RuntimeError("failed on text: my password is hunter2"))
    def test_tts_error_does_not_leak_user_text(self, mock_tts):
        r = client.post("/v1/tts", json={"text": "my password is hunter2"})
        assert r.status_code == 500
        error_msg = r.json()["error"]
        assert "hunter2" not in error_msg
        assert "password" not in error_msg
