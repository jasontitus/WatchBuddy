import SwiftUI

struct SettingsView: View {
    @AppStorage("server_url") private var serverURL = "https://bell-elliptic-adella.ngrok-free.dev"
    @AppStorage("ai_provider") private var aiProvider = "gemini"
    @AppStorage("has_api_key") private var hasApiKey = false
    @State private var apiKey = ""
    @State private var saved = false
    @State private var keyMode: NetworkManager.KeyMode?
    @State private var pendingModeCheck: DispatchWorkItem?
    @StateObject private var network = NetworkManager()

    private let providers = ["gemini", "openai", "anthropic"]

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            Section("AI Provider") {
                Picker("Provider", selection: $aiProvider) {
                    ForEach(providers, id: \.self) { provider in
                        Text(provider.capitalized).tag(provider)
                    }
                }
            }

            Section("API Key") {
                SecureField("Paste key", text: $apiKey)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainManager.save(key: "api_key", value: trimmed)
                        hasApiKey = true
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            saved = false
                        }
                        scheduleModeCheck()
                    }
                if saved {
                    Text("Key saved")
                        .font(.footnote)
                        .foregroundColor(.green)
                }
                if KeychainManager.load(key: "api_key") != nil {
                    keyStatusRow
                }
            }

            Section {
                Link("Privacy Policy", destination: URL(string: "https://jasontitus.github.io/WatchBuddy/privacy.html")!)
                    .font(.body)
                Text(versionString)
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Settings")
        .onAppear { network.checkKeyMode { keyMode = $0 } }
        .onChange(of: serverURL) { scheduleModeCheck() }
    }

    private var keyStatusRow: some View {
        HStack {
            Image(systemName: keyStatus.icon)
                .foregroundColor(keyStatus.color)
            Text(keyStatus.text)
                .font(.footnote)
                .foregroundColor(.gray)
        }
    }

    private var keyStatus: (icon: String, color: Color, text: String) {
        switch keyMode {
        case .serverKey:
            ("checkmark.seal.fill", .green, "Key matches family server")
        case .personalKey:
            ("exclamationmark.triangle.fill", .orange, "Key doesn't match server — will be used as a personal API key")
        case .serverUnreachable:
            ("wifi.slash", .orange, "Can't reach server to verify key")
        case .noKey, nil:
            ("checkmark.circle.fill", .green, "Key stored")
        }
    }

    // Debounced so per-keystroke saves don't fire a health request each.
    private func scheduleModeCheck() {
        pendingModeCheck?.cancel()
        let work = DispatchWorkItem {
            network.checkKeyMode { keyMode = $0 }
        }
        pendingModeCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
