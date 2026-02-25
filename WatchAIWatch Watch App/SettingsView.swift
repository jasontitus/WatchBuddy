import SwiftUI

struct SettingsView: View {
    @AppStorage("server_url") private var serverURL = "https://bell-elliptic-adella.ngrok-free.dev"
    @AppStorage("ai_provider") private var aiProvider = "gemini"
    @AppStorage("use_server_ai") private var useServerAI = false
    @State private var apiKey = ""
    @State private var saved = false

    private let providers = ["gemini", "openai", "anthropic"]

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Mode") {
                Toggle("Use Server's AI", isOn: $useServerAI)
                if useServerAI {
                    Text("Server handles everything. Enter the access key your server admin gave you.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                } else {
                    Text("Your API key goes directly to the AI provider. The server only does speech processing.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            if !useServerAI {
                Section("AI Provider") {
                    Picker("Provider", selection: $aiProvider) {
                        ForEach(providers, id: \.self) { provider in
                            Text(provider.capitalized).tag(provider)
                        }
                    }
                }
            }

            Section(useServerAI ? "Access Key" : "API Key") {
                SecureField("Paste key", text: $apiKey)
                    .autocorrectionDisabled()
                Button("Save Key") {
                    KeychainManager.save(key: "api_key", value: apiKey)
                    apiKey = ""
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saved = false
                    }
                }
                .disabled(apiKey.isEmpty)
                if saved {
                    Text("Key saved")
                        .font(.footnote)
                        .foregroundColor(.green)
                }
                if KeychainManager.load(key: "api_key") != nil {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Key stored")
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                }
            }
            Section {
                Link("Privacy Policy", destination: URL(string: "https://jasontitus.github.io/WatchBuddy/privacy.html")!)
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
    }
}
