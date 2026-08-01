# Troubleshooting network failures

## "Server error: A TLS error caused the secure connection to fail."

That banner is Apple's wording for `URLError.secureConnectionFailed` (`-1200`),
passed straight through by `NetworkManager`. It shows up intermittently while
the rest of the phone's or watch's internet works fine.

### Why it happens

TLS for the default server terminates at the **tunnel edge** (ngrok), not at
uvicorn — so a TLS error is a client↔edge problem, never a FastAPI problem.
Two things cause it:

1. **Stale pooled connections.** URLSession keeps HTTP/2 connections alive and
   reuses them. The tunnel edge drops idle connections, and the ngrok agent
   reconnects whenever the local server or the Mac's network hiccups
   (`com.watchai.ngrok.plist` has `KeepAlive`). The next request handshakes on a
   socket whose far end is already gone → `-1200`, or loses it mid-flight →
   `-1005 networkConnectionLost`. Because the dead connection stays pooled, an
   immediate retry by hand often fails the same way — which is what makes the
   failures look like they come in bursts.
2. **Link flaps on the device.** A watch drops off Wi-Fi constantly (wrist down,
   Wi-Fi↔cellular handoff, Bluetooth-proxied networking through the phone).
   Whatever connection was open at that moment dies.

### What the client now does

- Transient failures (`-1200`, `-1005`, timeouts, DNS, and 408/429/502/503/504
  from the tunnel edge) are retried twice with exponential backoff (0.5s, 1s),
  bounded by a 45-second window.
- Before a connection-level retry, `URLSession.flush` closes idle sockets, so
  the retry opens a **fresh** TCP/TLS connection instead of reusing the dead one.
- `waitsForConnectivity` lets a brief radio gap resolve itself rather than
  failing instantly.
- If it still fails, the banner says what to do — "Can't reach server (secure
  connection failed). Check Wi-Fi and the server URL." — and server errors now
  include the server's own message (e.g. `HTTP 401: Invalid access key`) instead
  of a bare status code.

### Confirming it from outside the app

Hammer `/health` and watch for the same failure. From a Mac on the same network:

```bash
for i in $(seq 1 50); do
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' \
    -H 'ngrok-skip-browser-warning: true' \
    https://YOUR_TUNNEL_DOMAIN/health || echo "curl failed"
  sleep 3
done
```

- Occasional `curl failed` / `SSL_ERROR_SYSCALL` → the tunnel edge, as described
  above.
- All 200s while the app still fails → the problem is device-side (Wi-Fi, VPN,
  private relay, or a captive-portal-style network).
- `502`/`504` → the tunnel is up but uvicorn behind it is down or restarting:
  `launchctl list | grep watchai` and check `Server/logs/`.

Xcode's console also prints the client's own retry lines:

```
[Net] /v1/text failed (A TLS error caused the secure connection to fail.) — retry in 0.5s, 2 left
```

If those lines appear and the request then succeeds, the retry ladder is doing
its job and no user-visible error should have surfaced.

## "AI error: …" right after a network blip

Trusted vs BYOK mode is auto-detected by comparing `sha256(api_key)` against
`access_key_hash` from `GET /health`. When that probe failed, the app used to
assume BYOK and send the **server access key** to Gemini/OpenAI/Anthropic as if
it were an LLM key — producing an unrelated-looking "AI error".

The hash is now cached in `UserDefaults` per server URL, so a failed probe can't
flip a trusted-mode user into BYOK, and when there is no cached hash at all the
app only proceeds if the stored key actually looks like a provider key
(`sk-…`, `AIza…`). Otherwise it reports "Can't reach server (no response from
/health)".

If you rotate `ACCESS_KEY` on the server, the app picks up the new hash on its
next launch (`fetchAccessKeyHash` runs `onAppear`); until then requests fail with
`HTTP 401: Invalid access key`.
