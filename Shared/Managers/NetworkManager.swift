import CommonCrypto
import Combine
import Foundation

struct VoiceResponse {
    let audioURL: URL
    let text: String
    let questionText: String
}

final class NetworkManager: NSObject, ObservableObject {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["ngrok-skip-browser-warning": "true"]
        // A watch (and a phone in a pocket) drops off Wi-Fi constantly: wrist
        // down, Wi-Fi/cellular handoff, Bluetooth-proxied networking. Waiting a
        // moment for a usable interface beats failing the request instantly.
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Extra attempts after the first one for a transient failure.
    private static let maxRetries = 2
    /// Delay before the first retry; doubles for each attempt after that.
    private static let initialBackoff: TimeInterval = 0.5
    /// Stop retrying once this long has passed since the first attempt, so a
    /// device that is genuinely offline fails instead of spinning for minutes
    /// (`waitsForConnectivity` lets a single attempt run to the resource
    /// timeout).
    private static let retryWindow: TimeInterval = 45

    private var serverURL: String {
        UserDefaults.standard.string(forKey: "server_url") ?? "https://bell-elliptic-adella.ngrok-free.dev"
    }

    private var aiProvider: String {
        UserDefaults.standard.string(forKey: "ai_provider") ?? "gemini"
    }

    private var apiKey: String {
        // Trim on read so keys saved with stray whitespace by older builds
        // still hash-match the server.
        (KeychainManager.load(key: "api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Written from URLSession callback threads, read from callers on others.
    private let accessKeyHashLock = NSLock()
    private var _cachedAccessKeyHash: String?

    // Persisted per server URL: the hash decides trusted vs BYOK mode, and a
    // single failed /health must not silently flip a trusted-mode user into
    // BYOK (which would ship their server access key to an LLM provider).
    private var accessKeyHashDefaultsKey: String { "access_key_hash::\(serverURL)" }

    private var cachedAccessKeyHash: String? {
        get {
            accessKeyHashLock.lock(); defer { accessKeyHashLock.unlock() }
            if let hash = _cachedAccessKeyHash { return hash }
            let stored = UserDefaults.standard.string(forKey: accessKeyHashDefaultsKey)
            _cachedAccessKeyHash = stored
            return stored
        }
        set {
            accessKeyHashLock.lock(); defer { accessKeyHashLock.unlock() }
            _cachedAccessKeyHash = newValue
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: accessKeyHashDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: accessKeyHashDefaultsKey)
            }
        }
    }

    private let systemPrompt = "You are a helpful voice assistant. Be concise. Reply in 1-2 short sentences. Never use markdown or special formatting."

    // MARK: - Request execution

    private struct HTTPResult {
        let data: Data
        let response: HTTPURLResponse
    }

    /// Failures that mean "try again", not "this request is wrong".
    ///
    /// The server is normally reached through a tunnel (ngrok) that terminates
    /// TLS at its edge. That edge closes idle connections, and the watch/phone
    /// link flaps on its own. URLSession keeps dead connections in its pool, so
    /// the next request can fail its handshake (`-1200 secureConnectionFailed`,
    /// surfaced as "A TLS error caused the secure connection to fail") or lose
    /// the connection mid-flight (`-1005`) while the rest of the internet is
    /// perfectly fine.
    private static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .secureConnectionFailed,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .badServerResponse,
             .zeroByteResource,
             .cannotLoadFromNetwork:
            return true
        default:
            // .notConnectedToInternet is deliberately absent: with
            // waitsForConnectivity the system already waited for a usable
            // interface, so retrying immediately only burns battery.
            return false
        }
    }

    /// 502/503/504 come from the tunnel edge while the app server behind it
    /// restarts; 408/429 are the server explicitly saying "come back".
    private static func isTransient(status: Int) -> Bool {
        status == 408 || status == 429 || (502...504).contains(status)
    }

    /// Runs a request, retrying transient failures with exponential backoff.
    /// The completion fires on a URLSession callback thread — callers hop to
    /// main themselves, as they did before.
    ///
    /// Every endpoint here is safe to repeat: a duplicated STT/LLM/TTS request
    /// only costs the server some work, and the client keeps one response.
    private func perform(_ request: URLRequest,
                         body: Data? = nil,
                         attemptsLeft: Int = NetworkManager.maxRetries,
                         backoff: TimeInterval = NetworkManager.initialBackoff,
                         startedAt: Date = Date(),
                         completion: @escaping (Result<HTTPResult, Error>) -> Void) {

        // Captured strongly on purpose: the closure only lives until the task
        // completes, and dropping it early would strand the caller's spinner.
        let handler: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            // Evaluated here, not before the request: an attempt that burned the
            // whole window has already used up the user's patience.
            let canRetry = attemptsLeft > 0 && Date().timeIntervalSince(startedAt) < NetworkManager.retryWindow

            if let error = error {
                guard canRetry, NetworkManager.isTransient(error) else {
                    completion(.failure(error)); return
                }
                self.scheduleRetry(request, body: body, attemptsLeft: attemptsLeft, backoff: backoff,
                                   startedAt: startedAt, newConnection: true,
                                   reason: error.localizedDescription, completion: completion)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(NetworkError.serverError(detail: "Invalid response"))); return
            }

            if canRetry, NetworkManager.isTransient(status: http.statusCode) {
                self.scheduleRetry(request, body: body, attemptsLeft: attemptsLeft, backoff: backoff,
                                   startedAt: startedAt, newConnection: false,
                                   reason: "HTTP \(http.statusCode)", completion: completion)
                return
            }

            completion(.success(HTTPResult(data: data ?? Data(), response: http)))
        }

        let task: URLSessionTask
        if let body = body {
            task = urlSession.uploadTask(with: request, from: body, completionHandler: handler)
        } else {
            task = urlSession.dataTask(with: request, completionHandler: handler)
        }
        task.resume()
    }

    private func scheduleRetry(_ request: URLRequest,
                               body: Data?,
                               attemptsLeft: Int,
                               backoff: TimeInterval,
                               startedAt: Date,
                               newConnection: Bool,
                               reason: String,
                               completion: @escaping (Result<HTTPResult, Error>) -> Void) {
        let path = request.url?.path ?? "?"
        print("[Net] \(path) failed (\(reason)) — retry in \(String(format: "%.1f", backoff))s, \(attemptsLeft) left")

        let again = {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + backoff) { [weak self] in
                guard let self = self else {
                    completion(.failure(NetworkError.serverError(detail: reason))); return
                }
                self.perform(request, body: body, attemptsLeft: attemptsLeft - 1,
                             backoff: backoff * 2, startedAt: startedAt, completion: completion)
            }
        }

        if newConnection {
            // Retrying on the same pooled connection would just fail the same
            // way. `flush` closes idle sockets so the retry opens a fresh
            // TCP/TLS connection.
            urlSession.flush(completionHandler: again)
        } else {
            again()
        }
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        guard let netError = error as? NetworkError, case .connectionFailed = netError else { return false }
        return true
    }

    /// Wraps whatever `perform` gave up on into a user-facing error.
    private static func networkFailure(_ error: Error) -> Error {
        if let known = error as? NetworkError { return known }
        return NetworkError.connectionFailed(reason: reason(for: error))
    }

    /// Turns a URLError into something a user can act on, instead of Apple's
    /// raw "A TLS error caused the secure connection to fail."
    private static func reason(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "secure connection failed"
        case .networkConnectionLost: return "connection dropped"
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "no internet connection"
        case .cannotFindHost, .dnsLookupFailed: return "server address not found"
        case .cannotConnectToHost: return "server refused the connection"
        default: return urlError.localizedDescription
        }
    }

    /// Includes the server's own `{"error": "..."}` message when it sent one.
    private static func detail(for result: HTTPResult) -> String {
        let code = result.response.statusCode
        if let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
           let message = json["error"] as? String, !message.isEmpty {
            return "HTTP \(code): \(message)"
        }
        return "HTTP \(code)"
    }

    /// Gemini, OpenAI and Anthropic all report failures the same way:
    /// `{"error": {"message": "..."}}`.
    private static func providerErrorDetail(_ result: HTTPResult) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return result.response.statusCode == 200 ? nil : "HTTP \(result.response.statusCode)"
    }

    // MARK: - Access key hash

    func fetchAccessKeyHash(completion: ((Bool) -> Void)? = nil) {
        guard let endpoint = URL(string: "\(serverURL)/health") else {
            completion?(false); return
        }

        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        perform(request) { [weak self] result in
            guard case .success(let http) = result,
                  http.response.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                  let hash = json["access_key_hash"] as? String else {
                completion?(false); return
            }
            self?.cachedAccessKeyHash = hash
            completion?(true)
        }
    }

    /// Decides trusted vs BYOK before the first request — and refuses to guess.
    ///
    /// Without the server's hash we cannot tell a trusted access key from an
    /// LLM key. Guessing BYOK would send the access key to Gemini/OpenAI/
    /// Anthropic and surface a nonsense "AI error", so only proceed when the
    /// key is recognisably a provider key.
    private func resolveMode(key: String,
                             onFailure: @escaping (Error) -> Void,
                             proceed: @escaping () -> Void) {
        guard cachedAccessKeyHash == nil else { proceed(); return }

        fetchAccessKeyHash { ok in
            if ok || NetworkManager.looksLikeProviderKey(key) {
                proceed()
            } else {
                DispatchQueue.main.async {
                    onFailure(NetworkError.connectionFailed(reason: "no response from /health"))
                }
            }
        }
    }

    private static func looksLikeProviderKey(_ key: String) -> Bool {
        key.hasPrefix("sk-") || key.hasPrefix("AIza")
    }

    enum KeyMode {
        case noKey
        case serverKey
        case personalKey
        case serverUnreachable
    }

    /// Re-fetches the server hash and reports how the stored key will be
    /// used, so Settings can surface a mismatch instead of silently falling
    /// back to BYOK. Completion runs on the main queue.
    func checkKeyMode(completion: @escaping (KeyMode) -> Void) {
        let finish: (KeyMode) -> Void = { mode in
            DispatchQueue.main.async { completion(mode) }
        }
        guard !apiKey.isEmpty else { finish(.noKey); return }
        fetchAccessKeyHash { [weak self] fetched in
            guard let self else { return }
            if !fetched {
                finish(.serverUnreachable)
            } else {
                finish(self.isTrustedKey ? .serverKey : .personalKey)
            }
        }
    }

    private var isTrustedKey: Bool {
        guard let serverHash = cachedAccessKeyHash, !serverHash.isEmpty else { return false }
        let key = apiKey
        guard !key.isEmpty else { return false }
        return sha256(key) == serverHash
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API

    func uploadRecording(fileURL: URL, history: [(question: String, answer: String)] = [], completion: @escaping (Result<VoiceResponse, Error>) -> Void) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(NetworkError.noAPIKey)); return
        }

        resolveMode(key: key, onFailure: { completion(.failure($0)) }) {
            if self.isTrustedKey {
                self.fullPipeline(fileURL: fileURL, history: history, completion: completion)
            } else {
                self.splitPipeline(fileURL: fileURL, apiKey: key, history: history, completion: completion)
            }
        }
    }

    func sendText(text: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(NetworkError.noAPIKey)); return
        }

        resolveMode(key: key, onFailure: { completion(.failure($0)) }) {
            if self.isTrustedKey {
                self.textPipeline(text: text, history: history, completion: completion)
            } else {
                self.callLLM(text: text, provider: self.aiProvider, apiKey: key, history: history, completion: completion)
            }
        }
    }

    /// Sends a photo (JPEG data, already downscaled by the caller) plus a
    /// question. Trusted mode goes through the server; BYOK only works with
    /// Gemini — the other providers' vision APIs aren't wired up.
    func sendImage(imageData: Data, text: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(NetworkError.noAPIKey)); return
        }

        resolveMode(key: key, onFailure: { completion(.failure($0)) }) {
            if self.isTrustedKey {
                self.imagePipeline(imageData: imageData, text: text, history: history, completion: completion)
            } else if self.aiProvider == "gemini" {
                self.callGeminiImage(imageData: imageData, text: text, apiKey: key, history: history, completion: completion)
            } else {
                DispatchQueue.main.async {
                    completion(.failure(NetworkError.llmError(detail: "Photo questions need the Gemini provider (see Settings)")))
                }
            }
        }
    }

    // MARK: - Text pipeline (trusted, server LLM)

    private func textPipeline(text: String, history: [(question: String, answer: String)], completion: @escaping (Result<String, Error>) -> Void) {
        guard let endpoint = URL(string: "\(serverURL)/v1/text") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["text": text, "api_key": apiKey]

        if !history.isEmpty {
            var contextMessages: [[String: String]] = []
            for turn in history {
                contextMessages.append(["role": "user", "content": turn.question])
                contextMessages.append(["role": "assistant", "content": turn.answer])
            }
            if let contextData = try? JSONSerialization.data(withJSONObject: contextMessages),
               let contextString = String(data: contextData, encoding: .utf8) {
                body["context"] = contextString
            }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard http.response.statusCode == 200 else {
                        completion(.failure(NetworkError.serverError(detail: NetworkManager.detail(for: http)))); return
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let responseText = json["response_text"] as? String else {
                        completion(.failure(NetworkError.serverError(detail: "Invalid response"))); return
                    }
                    completion(.success(responseText))
                }
            }
        }
    }

    // MARK: - Image pipeline (trusted, server LLM)

    private func imagePipeline(imageData: Data, text: String, history: [(question: String, answer: String)], completion: @escaping (Result<String, Error>) -> Void) {
        guard let endpoint = URL(string: "\(serverURL)/v1/image") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendFormField(boundary: boundary, name: "api_key", value: apiKey)
        body.appendFormField(boundary: boundary, name: "text", value: text)

        if !history.isEmpty {
            var contextMessages: [[String: String]] = []
            for turn in history {
                contextMessages.append(["role": "user", "content": turn.question])
                contextMessages.append(["role": "assistant", "content": turn.answer])
            }
            if let contextData = try? JSONSerialization.data(withJSONObject: contextMessages),
               let contextString = String(data: contextData, encoding: .utf8) {
                body.appendFormField(boundary: boundary, name: "context", value: contextString)
            }
        }

        body.appendFormFile(boundary: boundary, name: "file", filename: "photo.jpg", contentType: "image/jpeg", data: imageData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        perform(request, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard http.response.statusCode == 200 else {
                        completion(.failure(NetworkError.serverError(detail: NetworkManager.detail(for: http)))); return
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let responseText = json["response_text"] as? String else {
                        completion(.failure(NetworkError.serverError(detail: "Invalid response"))); return
                    }
                    completion(.success(responseText))
                }
            }
        }
    }

    // MARK: - Path 1: Full pipeline (trusted)

    private func fullPipeline(fileURL: URL, history: [(question: String, answer: String)], completion: @escaping (Result<VoiceResponse, Error>) -> Void) {
        guard let endpoint = URL(string: "\(serverURL)/v1/chat") else {
            completion(.failure(NetworkError.invalidURL))
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(.failure(NetworkError.fileReadFailed))
            return
        }

        var body = Data()
        body.appendFormField(boundary: boundary, name: "api_key", value: apiKey)

        if !history.isEmpty {
            var contextMessages: [[String: String]] = []
            for turn in history {
                contextMessages.append(["role": "user", "content": turn.question])
                contextMessages.append(["role": "assistant", "content": turn.answer])
            }
            if let contextData = try? JSONSerialization.data(withJSONObject: contextMessages),
               let contextString = String(data: contextData, encoding: .utf8) {
                body.appendFormField(boundary: boundary, name: "context", value: contextString)
            }
        }

        body.appendFormFile(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, contentType: "audio/mp4", data: fileData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        perform(request, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard http.response.statusCode == 200 else {
                        completion(.failure(NetworkError.serverError(detail: NetworkManager.detail(for: http)))); return
                    }
                    // The server returns an empty 200 body when STT produced no text
                    // (silence / unintelligible audio). Surface a friendly message
                    // instead of writing a 0-byte file that fails to play.
                    if http.data.isEmpty {
                        completion(.failure(NetworkError.emptyTranscription)); return
                    }
                    // Server percent-encodes these headers so non-ASCII text (em-dashes,
                    // accents, emoji) survives Latin-1 header transport intact.
                    let rawResponse = http.response.value(forHTTPHeaderField: "X-Response-Text") ?? ""
                    let rawQuestion = http.response.value(forHTTPHeaderField: "X-Question-Text") ?? ""
                    let responseText = rawResponse.removingPercentEncoding ?? rawResponse
                    let questionText = rawQuestion.removingPercentEncoding ?? rawQuestion
                    self.saveAndReturn(data: http.data, text: responseText, questionText: questionText, completion: completion)
                }
            }
        }
    }

    // MARK: - Path 2: Split pipeline (BYOK)

    private func splitPipeline(fileURL: URL, apiKey: String, history: [(question: String, answer: String)], completion: @escaping (Result<VoiceResponse, Error>) -> Void) {
        callSTT(fileURL: fileURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let questionText):
                if questionText.trimmingCharacters(in: .whitespaces).isEmpty {
                    completion(.failure(NetworkError.emptyTranscription)); return
                }
                self.callLLM(text: questionText, provider: self.aiProvider, apiKey: apiKey, history: history) { llmResult in
                    switch llmResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let responseText):
                        self.callTTS(text: responseText) { ttsResult in
                            switch ttsResult {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let audioURL):
                                completion(.success(VoiceResponse(audioURL: audioURL, text: responseText, questionText: questionText)))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Server: STT

    private func callSTT(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let endpoint = URL(string: "\(serverURL)/v1/stt") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(.failure(NetworkError.fileReadFailed)); return
        }

        var body = Data()
        body.appendFormFile(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, contentType: "audio/mp4", data: fileData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        perform(request, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard http.response.statusCode == 200 else {
                        completion(.failure(NetworkError.serverError(detail: NetworkManager.detail(for: http)))); return
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let text = json["text"] as? String else {
                        completion(.failure(NetworkError.serverError(detail: "Invalid response"))); return
                    }
                    completion(.success(text))
                }
            }
        }
    }

    // MARK: - Server: TTS

    private func callTTS(text: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let endpoint = URL(string: "\(serverURL)/v1/tts") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = try? JSONSerialization.data(withJSONObject: ["text": text])
        request.httpBody = body

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard http.response.statusCode == 200 else {
                        completion(.failure(NetworkError.serverError(detail: NetworkManager.detail(for: http)))); return
                    }
                    self.saveAudioAndReturn(data: http.data, completion: completion)
                }
            }
        }
    }

    // MARK: - Direct LLM calls (key stays on device)

    // One outer retry: `perform` already retries transient connection failures,
    // so this layer only covers content-level failures (a blocked or malformed
    // provider response) that a fresh request can still fix.
    private func callLLM(text: String, provider: String, apiKey: String, history: [(question: String, answer: String)] = [], retries: Int = 1, completion: @escaping (Result<String, Error>) -> Void) {
        let singleCall: (@escaping (Result<String, Error>) -> Void) -> Void = { cb in
            switch provider {
            case "openai":  self.callOpenAI(text: text, apiKey: apiKey, history: history, completion: cb)
            case "anthropic": self.callAnthropic(text: text, apiKey: apiKey, history: history, completion: cb)
            default:        self.callGemini(text: text, apiKey: apiKey, history: history, completion: cb)
            }
        }

        singleCall { result in
            switch result {
            case .success:
                completion(result)
            case .failure(let error):
                // A connection failure means `perform` already exhausted its
                // retries; going around again would only double the wait.
                if retries > 0, !NetworkManager.isConnectionFailure(error) {
                    print("[LLM] Retry (\(retries) left) after error: \(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.callLLM(text: text, provider: provider, apiKey: apiKey, history: history, retries: retries - 1, completion: completion)
                    }
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func callGemini(text: String, apiKey: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key goes in a header, not the URL: query strings leak into URL caches,
        // proxy logs, and error metadata.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var contents: [[String: Any]] = []
        for turn in history {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": turn.answer]]])
        }
        contents.append(["role": "user", "parts": [["text": text]]])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let candidates = json["candidates"] as? [[String: Any]],
                          let content = candidates.first?["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let responseText = parts.first?["text"] as? String else {
                        completion(.failure(NetworkError.llmError(detail: NetworkManager.providerErrorDetail(http)))); return
                    }
                    completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    private func callGeminiImage(imageData: Data, text: String, apiKey: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var contents: [[String: Any]] = []
        for turn in history {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": turn.answer]]])
        }
        contents.append(["role": "user", "parts": [
            ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]],
            ["text": text]
        ]])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let candidates = json["candidates"] as? [[String: Any]],
                          let content = candidates.first?["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let responseText = parts.first?["text"] as? String else {
                        completion(.failure(NetworkError.llmError(detail: NetworkManager.providerErrorDetail(http)))); return
                    }
                    completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    private func callOpenAI(text: String, apiKey: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": messages
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let message = choices.first?["message"] as? [String: Any],
                          let responseText = message["content"] as? String else {
                        completion(.failure(NetworkError.llmError(detail: NetworkManager.providerErrorDetail(http)))); return
                    }
                    completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    private func callAnthropic(text: String, apiKey: String, history: [(question: String, answer: String)] = [], completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: String]] = []
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(NetworkManager.networkFailure(error)))
                case .success(let http):
                    guard let json = try? JSONSerialization.jsonObject(with: http.data) as? [String: Any],
                          let content = json["content"] as? [[String: Any]],
                          let responseText = content.first?["text"] as? String else {
                        completion(.failure(NetworkError.llmError(detail: NetworkManager.providerErrorDetail(http)))); return
                    }
                    completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    // MARK: - Helpers

    private func saveAndReturn(data: Data, text: String, questionText: String, completion: @escaping (Result<VoiceResponse, Error>) -> Void) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let responseFile = documentsDir.appendingPathComponent("response.mp3")
        do {
            try data.write(to: responseFile)
            completion(.success(VoiceResponse(audioURL: responseFile, text: text, questionText: questionText)))
        } catch {
            completion(.failure(error))
        }
    }

    private func saveAudioAndReturn(data: Data, completion: @escaping (Result<URL, Error>) -> Void) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let responseFile = documentsDir.appendingPathComponent("response.mp3")
        do {
            try data.write(to: responseFile)
            completion(.success(responseFile))
        } catch {
            completion(.failure(error))
        }
    }

    enum NetworkError: LocalizedError {
        case invalidURL
        case fileReadFailed
        case serverError(detail: String?)
        case connectionFailed(reason: String)
        case noAPIKey
        case emptyTranscription
        case llmError(detail: String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Set your server URL in Settings"
            case .fileReadFailed: return "Could not read recording file"
            case .connectionFailed(let reason):
                // Every retry already failed by the time this surfaces. Kept
                // short: it has to fit a watch screen.
                return "Can't reach server (\(reason)). Check Wi-Fi and the server URL."
            case .serverError(let detail):
                if let detail = detail { return "Server error: \(detail)" }
                return "Could not reach server. Check your server URL in Settings."
            case .noAPIKey: return "Set your API key in Settings"
            case .emptyTranscription: return "Could not understand audio. Try speaking louder or closer."
            case .llmError(let detail):
                if let detail = detail { return "AI error: \(detail)" }
                return "AI provider returned an error. Check your API key in Settings."
            }
        }
    }
}

// MARK: - Data helpers for multipart form

extension Data {
    mutating func appendFormField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFormFile(boundary: String, name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
