import SwiftUI

enum AppState {
    case idle
    case recording
    case processing
    case playing
    case error
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let text: String
    var audioURL: URL? = nil
}

struct ContentView: View {
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var player = AudioPlayerManager()
    @StateObject private var network = NetworkManager()

    @AppStorage("server_url") private var serverURL = "https://bell-elliptic-adella.ngrok-free.dev"
    @AppStorage("has_api_key") private var hasApiKey = false

    @State private var appState: AppState = .idle
    @State private var triggerStopHaptic = false
    @State private var conversationHistory: [(question: String, answer: String)] = []
    @State private var chatMessages: [ChatMessage] = []
    @State private var textInput = ""
    @State private var errorMessage: String?
    @State private var playingMessageID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    private var isConfigured: Bool {
        let hasServer = !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasServer && hasApiKey
    }

    private var isBusy: Bool {
        appState == .recording || appState == .processing || appState == .playing
    }

    private var latestAudioMessageID: UUID? {
        chatMessages.last(where: { $0.role == "assistant" && $0.audioURL != nil })?.id
    }

    var body: some View {
        NavigationStack {
            if !isConfigured && appState == .idle {
                setupNeededView
            } else {
                chatView
            }
        }
    }

    // MARK: - Main chat view

    private var chatView: some View {
        VStack(spacing: 0) {
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    if chatMessages.isEmpty && appState == .idle {
                        emptyStateView
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(chatMessages) { message in
                                chatBubble(message)
                            }
                            if appState == .processing {
                                thinkingIndicator
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
                .onChange(of: chatMessages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: appState) { _, state in
                    if state == .processing {
                        scrollToBottom(proxy)
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !chatMessages.isEmpty {
                    Button(action: newConversation) {
                        Image(systemName: "plus.message")
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: triggerStopHaptic)
        .onAppear { network.fetchAccessKeyHash() }
        .onChange(of: serverURL) { _, _ in
            network.fetchAccessKeyHash()
        }
        .onChange(of: player.isPlaying) { _, playing in
            if !playing && appState == .playing {
                appState = .idle
                playingMessageID = nil
            }
        }
        .onChange(of: player.lastError) { _, err in
            if let err = err, appState == .playing {
                errorMessage = err
                appState = .error
                playingMessageID = nil
            }
        }
        .onChange(of: recorder.lastError) { _, err in
            if let err = err, appState == .recording {
                errorMessage = err
                appState = .error
            }
        }
        .onChange(of: recorder.silenceDetected) { _, detected in
            if detected && appState == .recording {
                stopRecording()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && appState == .playing && !player.isPlaying {
                appState = .idle
                playingMessageID = nil
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Tap the mic to speak or type a message")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if appState == .error, let msg = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button("Dismiss") { appState = .idle; errorMessage = nil }
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }

            if appState == .recording {
                recordingBar
            } else {
                textInputBar
            }
        }
    }

    private var recordingBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text("Listening... tap Submit when done")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: stopRecording) {
                Text("Submit")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.blue)
                    )
            }
            .buttonStyle(.plain)

            Button(action: cancelAction) {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var textInputBar: some View {
        HStack(spacing: 10) {
            TextField("Type a message...", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { sendTextMessage() }
                .disabled(isBusy)

            if appState == .processing {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else if canSendText {
                Button(action: sendTextMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
                }
            } else {
                Button(action: startRecording) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(isBusy ? .gray : .blue)
                }
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSendText: Bool {
        !textInput.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    // MARK: - Chat bubble

    private func chatBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.role == "user" ? Color.blue : Color(.systemGray5))
                    )
                    .foregroundColor(message.role == "user" ? .white : .primary)

                if message.role == "assistant",
                   let audioURL = message.audioURL,
                   message.id == latestAudioMessageID {
                    Button(action: { playAudio(url: audioURL, messageID: message.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: playingMessageID == message.id ? "stop.fill" : "play.fill")
                            Text(playingMessageID == message.id ? "Stop" : "Play")
                        }
                        .font(.caption)
                        .foregroundColor(.green)
                    }
                }
            }

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .id(message.id)
    }

    // MARK: - Thinking indicator

    private var thinkingIndicator: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Thinking...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray5))
            )
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 16)
        .id("loading")
    }

    // MARK: - Setup needed

    private var setupNeededView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "gear.badge")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Setup Required")
                .font(.title3)
                .bold()
            Text("Set your server URL and API key in Settings to get started.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            NavigationLink(destination: SettingsView()) {
                Text("Open Settings")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                }
            }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        recorder.startRecording()
        appState = .recording
    }

    private func stopRecording() {
        guard let fileURL = recorder.stopRecording() else {
            errorMessage = "No recording found"
            appState = .error
            return
        }

        appState = .processing
        triggerStopHaptic.toggle()

        network.uploadRecording(fileURL: fileURL, history: conversationHistory) { result in
            switch result {
            case .success(let response):
                let q = response.questionText
                let a = response.text
                if !q.isEmpty {
                    chatMessages.append(ChatMessage(role: "user", text: q))
                }
                if !a.isEmpty {
                    chatMessages.append(ChatMessage(role: "assistant", text: a, audioURL: response.audioURL))
                    conversationHistory.append((question: q, answer: a))
                }
                appState = .playing
                playingMessageID = chatMessages.last?.id
                player.play(url: response.audioURL)
            case .failure(let error):
                errorMessage = error.localizedDescription
                appState = .error
            }
        }
    }

    private func sendTextMessage() {
        let text = textInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        textInput = ""
        chatMessages.append(ChatMessage(role: "user", text: text))
        appState = .processing

        network.sendText(text: text, history: conversationHistory) { result in
            switch result {
            case .success(let response):
                chatMessages.append(ChatMessage(role: "assistant", text: response))
                conversationHistory.append((question: text, answer: response))
                appState = .idle
            case .failure(let error):
                errorMessage = error.localizedDescription
                appState = .error
            }
        }
    }

    private func playAudio(url: URL, messageID: UUID) {
        if playingMessageID == messageID {
            player.stop()
            playingMessageID = nil
            appState = .idle
        } else {
            playingMessageID = messageID
            appState = .playing
            player.play(url: url)
        }
    }

    private func cancelAction() {
        player.stop()
        _ = recorder.stopRecording()
        playingMessageID = nil
        appState = .idle
    }

    private func newConversation() {
        player.stop()
        _ = recorder.stopRecording()
        chatMessages = []
        conversationHistory = []
        textInput = ""
        errorMessage = nil
        playingMessageID = nil
        appState = .idle
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if appState == .processing {
                withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
            } else if let last = chatMessages.last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

#Preview {
    ContentView()
}
