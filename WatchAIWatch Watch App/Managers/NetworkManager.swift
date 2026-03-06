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
        return URLSession(configuration: config)
    }()

    private var serverURL: String {
        UserDefaults.standard.string(forKey: "server_url") ?? "https://bell-elliptic-adella.ngrok-free.dev"
    }

    private var aiProvider: String {
        UserDefaults.standard.string(forKey: "ai_provider") ?? "gemini"
    }

    private var apiKey: String {
        KeychainManager.load(key: "api_key") ?? ""
    }

    /// Cached access key hash fetched from the server's /health endpoint.
    private var cachedAccessKeyHash: String?

    private let systemPrompt = "You are a helpful voice assistant on an Apple Watch. Be concise. Reply in 1-2 short sentences. Never use markdown or special formatting."

    // MARK: - Access key hash

    /// Fetch the access key hash from the server and cache it.
    func fetchAccessKeyHash(completion: ((Bool) -> Void)? = nil) {
        guard let endpoint = URL(string: "\(serverURL)/health") else {
            completion?(false); return
        }

        let task = urlSession.dataTask(with: endpoint) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hash = json["access_key_hash"] as? String else {
                completion?(false); return
            }
            self?.cachedAccessKeyHash = hash
            completion?(true)
        }
        task.resume()
    }

    /// Check if the stored key is the trusted access key by comparing SHA-256 hashes locally.
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

        let proceed = {
            if self.isTrustedKey {
                self.fullPipeline(fileURL: fileURL, history: history, completion: completion)
            } else {
                self.splitPipeline(fileURL: fileURL, apiKey: key, history: history, completion: completion)
            }
        }

        if cachedAccessKeyHash == nil {
            fetchAccessKeyHash { _ in proceed() }
        } else {
            proceed()
        }
    }

    // MARK: - Path 1: Full pipeline (trusted friend)

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

        // Send conversation history as JSON context
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

        let task = urlSession.uploadTask(with: request, from: body) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(NetworkError.serverError(detail: error.localizedDescription))); return
                }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    let detail = code.map { "HTTP \($0)" }
                    completion(.failure(NetworkError.serverError(detail: detail))); return
                }
                let responseText = http.value(forHTTPHeaderField: "X-Response-Text") ?? ""
                let questionText = http.value(forHTTPHeaderField: "X-Question-Text") ?? ""
                self.saveAndReturn(data: data, text: responseText, questionText: questionText, completion: completion)
            }
        }
        task.resume()
    }

    // MARK: - Path 2: Split pipeline (BYOK - key never touches server)

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

        let task = urlSession.uploadTask(with: request, from: body) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(NetworkError.serverError(detail: error.localizedDescription))); return
                }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    let detail = code.map { "HTTP \($0)" }
                    completion(.failure(NetworkError.serverError(detail: detail))); return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    completion(.failure(NetworkError.serverError(detail: "Invalid response"))); return
                }
                completion(.success(text))
            }
        }
        task.resume()
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

        let task = urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(NetworkError.serverError(detail: error.localizedDescription))); return
                }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    let detail = code.map { "HTTP \($0)" }
                    completion(.failure(NetworkError.serverError(detail: detail))); return
                }
                self.saveAudioAndReturn(data: data, completion: completion)
            }
        }
        task.resume()
    }

    // MARK: - Direct LLM calls (key stays on watch)

    private func callLLM(text: String, provider: String, apiKey: String, history: [(question: String, answer: String)] = [], retries: Int = 2, completion: @escaping (Result<String, Error>) -> Void) {
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
                if retries > 0 {
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
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        let task = urlSession.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let responseText = parts.first?["text"] as? String else {
                    completion(.failure(NetworkError.llmError(detail: nil))); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
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

        let task = urlSession.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let responseText = message["content"] as? String else {
                    completion(.failure(NetworkError.llmError(detail: nil))); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
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

        let task = urlSession.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let responseText = content.first?["text"] as? String else {
                    completion(.failure(NetworkError.llmError(detail: nil))); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
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
        case noAPIKey
        case emptyTranscription
        case llmError(detail: String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Set your server URL in Settings"
            case .fileReadFailed: return "Could not read recording file"
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
