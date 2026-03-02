"""
Test client for all WatchAI server endpoints.

Usage:
    python test_client.py <path_to_audio_file> [server_url]

Example:
    python test_client.py test_recording.m4a http://localhost:8000
"""

import os
import sys

import requests
from dotenv import load_dotenv

load_dotenv()

DEFAULT_URL = "http://localhost:8000"


def test_health(base_url: str):
    print("\n=== GET /health ===")
    r = requests.get(f"{base_url}/health", timeout=5)
    print(f"Status: {r.status_code}")
    data = r.json()
    print(f"Response: {data}")
    assert r.status_code == 200
    assert data["status"] == "ok"
    assert "access_key_hash" in data
    print("PASS")
    return data["access_key_hash"]


def test_stt(base_url: str, audio_path: str):
    print("\n=== POST /v1/stt ===")
    with open(audio_path, "rb") as f:
        files = {"file": (audio_path, f, "audio/mp4")}
        r = requests.post(f"{base_url}/v1/stt", files=files, timeout=30)
    print(f"Status: {r.status_code}")
    data = r.json()
    print(f"Transcription: {data.get('text', '')}")
    assert r.status_code == 200
    assert "text" in data
    print("PASS")
    return data["text"]


def test_tts(base_url: str, text: str):
    print("\n=== POST /v1/tts ===")
    r = requests.post(f"{base_url}/v1/tts", json={"text": text}, timeout=30)
    print(f"Status: {r.status_code}")
    print(f"Content-Type: {r.headers.get('content-type')}")
    print(f"Response size: {len(r.content)} bytes")
    assert r.status_code == 200
    assert len(r.content) > 0
    with open("tts_output.mp3", "wb") as f:
        f.write(r.content)
    print("Saved to tts_output.mp3")
    print("PASS")


def test_chat_with_valid_key(base_url: str, audio_path: str):
    print("\n=== POST /v1/chat (valid key) ===")
    access_key = os.getenv("ACCESS_KEY", "")
    if not access_key:
        print("SKIP - no ACCESS_KEY in .env")
        return

    with open(audio_path, "rb") as f:
        files = {"file": (audio_path, f, "audio/mp4")}
        data = {"api_key": access_key}
        r = requests.post(f"{base_url}/v1/chat", files=files, data=data, timeout=30)
    print(f"Status: {r.status_code}")
    print(f"Content-Type: {r.headers.get('content-type')}")
    print(f"Response size: {len(r.content)} bytes")
    assert r.status_code == 200
    assert len(r.content) > 0
    with open("chat_output.mp3", "wb") as f:
        f.write(r.content)
    print("Saved to chat_output.mp3")
    print("PASS")


def test_chat_with_bad_key(base_url: str, audio_path: str):
    print("\n=== POST /v1/chat (bad key) ===")
    with open(audio_path, "rb") as f:
        files = {"file": (audio_path, f, "audio/mp4")}
        data = {"api_key": "wrong-key"}
        r = requests.post(f"{base_url}/v1/chat", files=files, data=data, timeout=30)
    print(f"Status: {r.status_code}")
    print(f"Response: {r.text}")
    assert r.status_code == 401
    print("PASS")


def main():
    if len(sys.argv) < 2:
        print("Usage: python test_client.py <audio_file> [server_url]")
        print("Example: python test_client.py recording.m4a http://localhost:8000")
        sys.exit(1)

    audio_path = sys.argv[1]
    base_url = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_URL

    print(f"Testing server at {base_url} with audio file: {audio_path}")

    test_health(base_url)
    text = test_stt(base_url, audio_path)
    test_tts(base_url, text or "Hello, this is a test of text to speech.")
    test_chat_with_bad_key(base_url, audio_path)
    test_chat_with_valid_key(base_url, audio_path)

    print("\n=== All tests passed! ===")


if __name__ == "__main__":
    main()
