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
from urllib.parse import unquote
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
        assert unquote(r.headers["x-response-text"]) == "Hello there!"
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
        assert unquote(r.headers["x-question-text"]) == "Hi"

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
        assert unquote(r.headers["x-question-text"]) == "And what about dessert?"
        assert unquote(r.headers["x-response-text"]) == "Response after multi-turn"
        call_kwargs = mock_llm.call_args
        assert len(call_kwargs[1]["history"]) == 4

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Café — 30°C, naïve résumé 🌞")
    @patch("main.transcribe", return_value="Comment ça va?")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_non_ascii_headers_round_trip(self, mock_transcode, mock_stt, mock_llm, mock_tts):
        """Non-Latin-1 text must survive the response headers intact."""
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200
        # Raw header is ASCII-safe (percent-encoded)...
        assert r.headers["x-response-text"].isascii()
        # ...and decodes losslessly.
        assert unquote(r.headers["x-response-text"]) == "Café — 30°C, naïve résumé 🌞"
        assert unquote(r.headers["x-question-text"]) == "Comment ça va?"

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


# ──────────────────────────────────────────────
# HEAD /health
# ──────────────────────────────────────────────

class TestHealthHEAD:
    def test_head_health_returns_200(self):
        r = client.head("/health")
        assert r.status_code == 200

    def test_head_health_has_no_body(self):
        r = client.head("/health")
        assert r.status_code == 200
        # HEAD responses should have empty body
        assert len(r.content) == 0


# ──────────────────────────────────────────────
# Chat auth edge cases
# ──────────────────────────────────────────────

class TestChatAuth:
    def test_chat_missing_api_key_returns_422(self):
        """Missing api_key form field entirely."""
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 422

    def test_chat_empty_api_key_is_rejected(self):
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": ""},
        )
        # An empty key is never valid: rejected as 401 (handler) or 422 (form
        # validation, depending on python-multipart version). Either way it must
        # not reach the pipeline.
        assert r.status_code in (401, 422)

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    @patch("main.ask_gemini", return_value="Response")
    @patch("main.transcribe", return_value="Hi")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_chat_without_context_field_succeeds(self, mock_t, mock_s, mock_g, mock_tts):
        """Chat request with no context form field at all (not even empty)."""
        r = client.post(
            "/v1/chat",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            data={"api_key": VALID_KEY},
        )
        assert r.status_code == 200
        # ask_gemini should be called with history=None
        mock_g.assert_called_once()
        assert mock_g.call_args[1]["history"] is None


# ──────────────────────────────────────────────
# STT no-auth verification
# ──────────────────────────────────────────────

class TestSTTNoAuth:
    @patch("main.transcribe", return_value="No key needed")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_stt_requires_no_api_key(self, mock_transcode, mock_stt):
        """STT endpoint works without any api_key."""
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
        )
        assert r.status_code == 200
        assert r.json()["text"] == "No key needed"


class TestOptionalSTTTTSAuth:
    """REQUIRE_AUTH_STT_TTS=1 gates /v1/stt and /v1/tts behind the access key."""

    def test_stt_rejects_missing_key_when_required(self):
        with patch("main.REQUIRE_AUTH_STT_TTS", True):
            r = client.post(
                "/v1/stt",
                files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
            )
        assert r.status_code == 401

    @patch("main.transcribe", return_value="Authed")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_stt_accepts_valid_key_when_required(self, mock_t, mock_s):
        with patch("main.REQUIRE_AUTH_STT_TTS", True):
            r = client.post(
                "/v1/stt",
                files={"file": ("test.m4a", io.BytesIO(FAKE_AUDIO), "audio/mp4")},
                data={"api_key": VALID_KEY},
            )
        assert r.status_code == 200

    def test_tts_rejects_missing_key_when_required(self):
        with patch("main.REQUIRE_AUTH_STT_TTS", True):
            r = client.post("/v1/tts", json={"text": "Hello"})
        assert r.status_code == 401

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    def test_tts_accepts_valid_key_when_required(self, mock_tts):
        with patch("main.REQUIRE_AUTH_STT_TTS", True):
            r = client.post("/v1/tts", json={"text": "Hello", "api_key": VALID_KEY})
        assert r.status_code == 200


# ──────────────────────────────────────────────
# TTS edge cases
# ──────────────────────────────────────────────

class TestTTSEdgeCases:
    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 10)
    def test_tts_with_whitespace_only_text_returns_400(self, mock_tts):
        """Whitespace-only text has no speech to synthesize and is rejected."""
        r = client.post("/v1/tts", json={"text": "   "})
        assert r.status_code == 400
        mock_tts.assert_not_called()

    def test_tts_no_body_returns_422(self):
        r = client.post("/v1/tts")
        assert r.status_code == 422

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    def test_tts_response_has_content_disposition(self, mock_tts):
        r = client.post("/v1/tts", json={"text": "Hello"})
        assert r.status_code == 200
        assert "response.mp3" in r.headers.get("content-disposition", "")

    @patch("main.synthesize_speech", return_value=b"\xff\xfb\x90\x00" * 100)
    def test_tts_truncates_overly_long_text(self, mock_tts):
        from main import MAX_TTS_CHARS
        r = client.post("/v1/tts", json={"text": "a" * (MAX_TTS_CHARS + 500)})
        assert r.status_code == 200
        # synthesize_speech is called with text capped at MAX_TTS_CHARS
        called_text = mock_tts.call_args[0][0]
        assert len(called_text) == MAX_TTS_CHARS


# ──────────────────────────────────────────────
# ask_gemini unit tests
# ──────────────────────────────────────────────

class TestAskGemini:
    @patch("main.gemini_client")
    def test_ask_gemini_no_history(self, mock_client):
        from main import ask_gemini
        mock_response = MagicMock()
        mock_response.text = "  Test response  "
        mock_client.models.generate_content.return_value = mock_response

        result = ask_gemini("Hello")
        assert result == "Test response"

        call_args = mock_client.models.generate_content.call_args
        contents = call_args[1]["contents"]
        assert len(contents) == 1
        assert contents[0]["role"] == "user"
        assert contents[0]["parts"][0]["text"] == "Hello"

    @patch("main.gemini_client")
    def test_ask_gemini_with_history_maps_roles(self, mock_client):
        """Verify assistant role maps to 'model' for Gemini API."""
        from main import ask_gemini
        mock_response = MagicMock()
        mock_response.text = "Response"
        mock_client.models.generate_content.return_value = mock_response

        history = [
            {"role": "user", "content": "Q1"},
            {"role": "assistant", "content": "A1"},
            {"role": "user", "content": "Q2"},
            {"role": "assistant", "content": "A2"},
        ]
        ask_gemini("Q3", history=history)

        call_args = mock_client.models.generate_content.call_args
        contents = call_args[1]["contents"]
        assert len(contents) == 5  # 4 history + 1 current
        assert contents[0]["role"] == "user"
        assert contents[1]["role"] == "model"  # assistant -> model
        assert contents[2]["role"] == "user"
        assert contents[3]["role"] == "model"  # assistant -> model
        assert contents[4]["role"] == "user"
        assert contents[4]["parts"][0]["text"] == "Q3"

    @patch("main.gemini_client")
    def test_ask_gemini_with_empty_history(self, mock_client):
        """Empty history list should behave like no history."""
        from main import ask_gemini
        mock_response = MagicMock()
        mock_response.text = "Response"
        mock_client.models.generate_content.return_value = mock_response

        ask_gemini("Hello", history=[])

        call_args = mock_client.models.generate_content.call_args
        contents = call_args[1]["contents"]
        assert len(contents) == 1  # empty list is falsy, no history added

    @patch("main.gemini_client")
    def test_ask_gemini_none_text_returns_fallback(self, mock_client):
        """A blocked/empty Gemini response (text=None) must not crash."""
        from main import ask_gemini
        mock_response = MagicMock()
        mock_response.text = None  # Gemini returns None when content is blocked
        mock_client.models.generate_content.return_value = mock_response

        result = ask_gemini("Hello")
        assert isinstance(result, str)
        assert result  # non-empty fallback

    @patch("main.time.sleep", return_value=None)
    @patch("main.gemini_client")
    def test_ask_gemini_retries_transient_failure(self, mock_client, _sleep):
        """A first-attempt failure should be retried and succeed."""
        from main import ask_gemini
        ok = MagicMock()
        ok.text = "recovered"
        mock_client.models.generate_content.side_effect = [
            RuntimeError("transient 503"),
            ok,
        ]
        result = ask_gemini("Hello")
        assert result == "recovered"
        assert mock_client.models.generate_content.call_count == 2

    @patch("main.time.sleep", return_value=None)
    @patch("main.gemini_client")
    def test_ask_gemini_raises_after_exhausting_retries(self, mock_client, _sleep):
        """Persistent failure should propagate (endpoint maps it to 500)."""
        from main import ask_gemini, LLM_MAX_ATTEMPTS
        mock_client.models.generate_content.side_effect = RuntimeError("down")
        with pytest.raises(RuntimeError):
            ask_gemini("Hello")
        assert mock_client.models.generate_content.call_count == LLM_MAX_ATTEMPTS

    @patch("main.gemini_client")
    def test_ask_gemini_skips_malformed_history_entries(self, mock_client):
        """History entries missing content should be skipped, not crash."""
        from main import ask_gemini
        mock_response = MagicMock()
        mock_response.text = "ok"
        mock_client.models.generate_content.return_value = mock_response

        history = [
            {"role": "user", "content": "Q1"},
            {"role": "assistant"},          # missing content
            {"role": "user", "content": ""},  # empty content
            {"role": "assistant", "content": "A1"},
        ]
        ask_gemini("Q2", history=history)
        contents = mock_client.models.generate_content.call_args[1]["contents"]
        # Q1, A1, then current Q2 — malformed entries dropped
        assert len(contents) == 3


# ──────────────────────────────────────────────
# parse_history validation
# ──────────────────────────────────────────────

class TestParseHistory:
    def test_none_for_empty_string(self):
        from main import parse_history
        assert parse_history("") is None

    def test_none_for_invalid_json(self):
        from main import parse_history
        assert parse_history("not json{{{") is None

    def test_none_for_non_list(self):
        from main import parse_history
        assert parse_history(json.dumps({"role": "user", "content": "hi"})) is None

    def test_drops_malformed_entries(self):
        from main import parse_history
        ctx = json.dumps([
            {"role": "user", "content": "keep"},
            "a string, not a dict",
            {"role": "assistant"},        # no content
            {"content": "  "},            # blank content
            {"role": "assistant", "content": "keep2"},
        ])
        result = parse_history(ctx)
        assert result == [
            {"role": "user", "content": "keep"},
            {"role": "assistant", "content": "keep2"},
        ]

    def test_caps_history_length(self):
        from main import parse_history, MAX_HISTORY_TURNS
        msgs = [{"role": "user", "content": f"m{i}"} for i in range(100)]
        result = parse_history(json.dumps(msgs))
        assert len(result) == MAX_HISTORY_TURNS * 2
        # Most recent messages are kept
        assert result[-1]["content"] == "m99"


# ──────────────────────────────────────────────
# verify_access_key
# ──────────────────────────────────────────────

class TestVerifyAccessKey:
    def test_correct_key(self):
        from main import verify_access_key
        assert verify_access_key(VALID_KEY) is True

    def test_wrong_key(self):
        from main import verify_access_key
        assert verify_access_key("nope") is False

    def test_empty_key(self):
        from main import verify_access_key
        assert verify_access_key("") is False


# ──────────────────────────────────────────────
# Boundary / edge cases
# ──────────────────────────────────────────────

class TestBoundaryEdgeCases:
    def test_stt_oversized_file_at_exact_boundary(self):
        """File exactly 1 byte over the limit."""
        data = b"\x00" * (MAX_UPLOAD_BYTES + 1)
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(data), "audio/mp4")},
        )
        assert r.status_code == 400

    @patch("main.transcribe", return_value="Boundary test")
    @patch("main.transcode_to_wav", return_value=b"RIFF" + b"\x00" * 100)
    def test_stt_exactly_at_size_limit_succeeds(self, mock_t, mock_s):
        data = b"\x00" * MAX_UPLOAD_BYTES
        r = client.post(
            "/v1/stt",
            files={"file": ("test.m4a", io.BytesIO(data), "audio/mp4")},
        )
        assert r.status_code == 200

    def test_oversized_declared_body_returns_413(self):
        """The middleware rejects an oversized Content-Length before parsing."""
        from main import MAX_BODY_BYTES
        r = client.post(
            "/v1/stt",
            content=b"x",
            headers={
                "Content-Length": str(MAX_BODY_BYTES + 1),
                "Content-Type": "application/octet-stream",
            },
        )
        assert r.status_code == 413

    @patch("main.ask_gemini", return_value="ok")
    def test_text_chat_too_long_returns_400(self, mock_llm):
        from main import MAX_TEXT_CHARS
        r = client.post(
            "/v1/text",
            json={"text": "a" * (MAX_TEXT_CHARS + 1), "api_key": VALID_KEY},
        )
        assert r.status_code == 400
        mock_llm.assert_not_called()

    def test_parse_history_truncates_long_messages(self):
        from main import parse_history, MAX_HISTORY_MSG_CHARS
        ctx = json.dumps([{"role": "user", "content": "x" * (MAX_HISTORY_MSG_CHARS * 3)}])
        history = parse_history(ctx)
        assert history is not None
        assert len(history[0]["content"]) == MAX_HISTORY_MSG_CHARS

    def test_unknown_endpoint_returns_404(self):
        r = client.get("/v1/nonexistent")
        assert r.status_code in (404, 405)

    def test_chat_wrong_method_returns_405(self):
        r = client.get("/v1/chat")
        assert r.status_code == 405
