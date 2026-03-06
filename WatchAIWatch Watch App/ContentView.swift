import SwiftUI
import WatchKit

enum AppState {
    case idle
    case recording
    case processing
    case playing
    case done
    case error
}

struct ContentView: View {
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var player = AudioPlayerManager()
    @StateObject private var network = NetworkManager()
    @StateObject private var session = SessionManager()

    @AppStorage("server_url") private var serverURL = "https://bell-elliptic-adella.ngrok-free.dev"

    @State private var appState: AppState = .idle
    @State private var responseURL: URL?
    @State private var responseText: String?
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private var isConfigured: Bool {
        let hasServer = !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = KeychainManager.load(key: "api_key") != nil
        return hasServer && hasKey
    }

    var body: some View {
        NavigationStack {
        VStack(spacing: 16) {
            if !isConfigured && appState == .idle {
                setupNeededView
            } else {
                switch appState {
                case .idle:
                    Spacer()
                    recordButton
                    Spacer()

                case .recording:
                    Spacer()
                    stopButton
                    Text("Listening...")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    Spacer()

                case .processing:
                    Spacer()
                    ProgressView()
                        .tint(.blue)
                    Text("Processing...")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    Spacer()

                case .playing:
                    Spacer()
                    ProgressView()
                        .tint(.green)
                    Text("Playing...")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    Spacer()

                case .done:
                    responseView

                case .error:
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                    Text(errorMessage ?? "Something went wrong")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    newRecordingButton
                    Spacer()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                }
            }
        }
        .onAppear { network.fetchAccessKeyHash() }
        .onChange(of: player.isPlaying) { playing in
            if !playing && appState == .playing {
                if let err = player.lastError {
                    errorMessage = err
                    appState = .error
                } else {
                    appState = .done
                }
            }
        }
        .onChange(of: player.lastError) { err in
            if let err = err, appState == .playing {
                errorMessage = err
                appState = .error
            }
        }
        .onChange(of: recorder.lastError) { err in
            if let err = err, appState == .recording {
                errorMessage = err
                appState = .error
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && appState == .playing && !player.isPlaying {
                appState = .done
            }
        }
        } // NavigationStack
    }

    // MARK: - Response view

    private var responseView: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let text = responseText, !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 16) {
                    Button(action: replayResponse) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.green))
                    }
                    .buttonStyle(.plain)

                    Button(action: newRecording) {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Setup needed

    private var setupNeededView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gear.badge")
                .font(.title2)
                .foregroundColor(.orange)
            Text("Setup Required")
                .font(.footnote)
                .bold()
            Text("Set your server URL and API key in Settings to get started.")
                .font(.caption2)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            NavigationLink(destination: SettingsView()) {
                Text("Open Settings")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Buttons

    private var recordButton: some View {
        Button(action: startRecording) {
            Image(systemName: "mic.fill")
                .font(.system(size: 32))
                .foregroundColor(.white)
                .frame(width: 80, height: 80)
                .background(Circle().fill(Color.blue))
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button(action: stopRecording) {
            Image(systemName: "stop.fill")
                .font(.system(size: 32))
                .foregroundColor(.white)
                .frame(width: 80, height: 80)
                .background(Circle().fill(Color.red))
        }
        .buttonStyle(.plain)
    }

    private var newRecordingButton: some View {
        Button("New Recording") {
            newRecording()
        }
        .font(.footnote)
        .foregroundColor(.blue)
    }

    // MARK: - Actions

    private func startRecording() {
        session.startSession()
        recorder.startRecording()
        appState = .recording
    }

    private func stopRecording() {
        guard let fileURL = recorder.stopRecording() else {
            appState = .error
            errorMessage = "No recording found"
            return
        }

        appState = .processing
        WKInterfaceDevice.current().play(.click)

        network.uploadRecording(fileURL: fileURL) { result in
            switch result {
            case .success(let response):
                responseURL = response.audioURL
                responseText = response.text
                appState = .playing
                player.play(url: response.audioURL)
            case .failure(let error):
                errorMessage = error.localizedDescription
                appState = .error
            }
            session.endSession()
        }
    }

    private func replayResponse() {
        guard let url = responseURL else { return }
        appState = .playing
        player.play(url: url)
    }

    private func newRecording() {
        player.stop()
        responseURL = nil
        responseText = nil
        appState = .idle
    }
}

#Preview {
    ContentView()
}
