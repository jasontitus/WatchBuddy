import SwiftUI
import WatchKit

enum AppState {
    case idle
    case recording
    case processing
    case ready
    case playing
    case error
}

struct ContentView: View {
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var player = AudioPlayerManager()
    @StateObject private var network = NetworkManager()
    @StateObject private var session = SessionManager()

    @State private var appState: AppState = .idle
    @State private var responseURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
        VStack(spacing: 16) {
            Spacer()

            switch appState {
            case .idle:
                recordButton

            case .recording:
                stopButton
                Text("Listening...")
                    .font(.footnote)
                    .foregroundColor(.gray)

            case .processing:
                ProgressView()
                    .tint(.blue)
                Text("Processing...")
                    .font(.footnote)
                    .foregroundColor(.gray)

            case .ready:
                playButton
                resetButton

            case .playing:
                ProgressView()
                    .tint(.green)
                Text("Playing...")
                    .font(.footnote)
                    .foregroundColor(.gray)

            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
                Text(errorMessage ?? "Something went wrong")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                resetButton
            }

            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                }
            }
        }
        .onChange(of: player.isPlaying) { playing in
            if !playing && appState == .playing {
                appState = .ready
            }
        }
        } // NavigationStack
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

    private var playButton: some View {
        Button(action: playResponse) {
            Image(systemName: "play.fill")
                .font(.system(size: 32))
                .foregroundColor(.white)
                .frame(width: 80, height: 80)
                .background(Circle().fill(Color.green))
        }
        .buttonStyle(.plain)
    }

    private var resetButton: some View {
        Button("New Recording") {
            player.stop()
            appState = .idle
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
            case .success(let url):
                responseURL = url
                appState = .playing
                player.play(url: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
                appState = .error
            }
            session.endSession()
        }
    }

    private func playResponse() {
        guard let url = responseURL else { return }
        appState = .playing
        player.play(url: url)
    }
}

#Preview {
    ContentView()
}
