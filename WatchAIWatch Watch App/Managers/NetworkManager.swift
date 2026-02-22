import Combine
import Foundation

final class NetworkManager: NSObject, ObservableObject {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    private var serverURL: String {
        UserDefaults.standard.string(forKey: "server_url") ?? ""
    }

    private var aiProvider: String {
        UserDefaults.standard.string(forKey: "ai_provider") ?? "gemini"
    }

    private var apiKey: String {
        KeychainManager.load(key: "api_key") ?? ""
    }

    private var useServerAI: Bool {
        UserDefaults.standard.bool(forKey: "use_server_ai")
    }

    private let systemPrompt = "You are a helpful voice assistant on an Apple Watch. Be concise. Reply in 1-2 short sentences. Never use markdown or special formatting."

    // MARK: - Public API

    func uploadRecording(fileURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let key = apiKey

        if useServerAI {
            // Path 1: Server does everything (trusted friend mode)
            // Sends the trusted access key so the server validates it
            fullPipeline(fileURL: fileURL, completion: completion)
        } else if !key.isEmpty {
            // Path 2: Three round trips, API key never touches server
            splitPipeline(fileURL: fileURL, apiKey: key, completion: completion)
        } else {
            completion(.failure(NetworkError.noAPIKey))
        }
    }

    // MARK: - Path 1: Full pipeline (trusted friend)

    private func fullPipeline(fileURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
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
        // Send the trusted access key so server validates and uses its own AI key
        body.appendFormField(boundary: boundary, name: "api_key", value: apiKey)
        body.appendFormFile(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, contentType: "audio/mp4", data: fileData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let task = urlSession.uploadTask(with: request, from: body) { data, response, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    completion(.failure(NetworkError.serverError)); return
                }
                self.saveAndReturn(data: data, completion: completion)
            }
        }
        task.resume()
    }

    // MARK: - Path 2: Split pipeline (BYOK - key never touches server)

    private func splitPipeline(fileURL: URL, apiKey: String, completion: @escaping (Result<URL, Error>) -> Void) {
        // Step 1: STT on server
        callSTT(fileURL: fileURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let text):
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    completion(.failure(NetworkError.emptyTranscription)); return
                }
                // Step 2: LLM directly from watch (key stays on device)
                self.callLLM(text: text, provider: self.aiProvider, apiKey: apiKey) { llmResult in
                    switch llmResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let responseText):
                        // Step 3: TTS on server
                        self.callTTS(text: responseText, completion: completion)
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    completion(.failure(NetworkError.serverError)); return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    completion(.failure(NetworkError.serverError)); return
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
                if let error = error { completion(.failure(error)); return }
                guard let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    completion(.failure(NetworkError.serverError)); return
                }
                self.saveAndReturn(data: data, completion: completion)
            }
        }
        task.resume()
    }

    // MARK: - Direct LLM calls (key stays on watch)

    private func callLLM(text: String, provider: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        switch provider {
        case "openai":  callOpenAI(text: text, apiKey: apiKey, completion: completion)
        case "anthropic": callAnthropic(text: text, apiKey: apiKey, completion: completion)
        default:        callGemini(text: text, apiKey: apiKey, completion: completion)
        }
    }

    private func callGemini(text: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": [["text": text]]]]
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
                    completion(.failure(NetworkError.llmError)); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
    }

    private func callOpenAI(text: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
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
                    completion(.failure(NetworkError.llmError)); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
    }

    private func callAnthropic(text: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(NetworkError.invalidURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = urlSession.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let responseText = content.first?["text"] as? String else {
                    completion(.failure(NetworkError.llmError)); return
                }
                completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    private func saveAndReturn(data: Data, completion: @escaping (Result<URL, Error>) -> Void) {
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
        case serverError
        case noAPIKey
        case emptyTranscription
        case llmError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Set your server URL in Settings"
            case .fileReadFailed: return "Could not read recording file"
            case .serverError: return "Server returned an error"
            case .noAPIKey: return "Set your API key in Settings"
            case .emptyTranscription: return "Could not understand audio"
            case .llmError: return "AI provider returned an error"
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
