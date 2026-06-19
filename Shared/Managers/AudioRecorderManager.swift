import AVFoundation
import Combine

/// Records microphone audio to an M4A file. Shared by the watch and iOS targets.
///
/// Platform differences are isolated with `#if os(...)`:
/// - iOS routes playback to the speaker (`.defaultToSpeaker`).
/// - The mic-permission denied message names the right Settings location.
///
/// `silenceDetected` is published for callers that want to auto-stop after a
/// pause (the iOS app observes it); targets that don't observe it are unaffected.
final class AudioRecorderManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var lastError: String?
    @Published var silenceDetected = false

    private var recorder: AVAudioRecorder?
    private(set) var recordingURL: URL?
    private var silenceTimer: Timer?
    private var hasDetectedSpeech = false
    private let silenceThreshold: Float = -40.0 // dB
    private let silenceTimeout: TimeInterval = 4.0

    func startRecording() {
        lastError = nil
        silenceDetected = false
        hasDetectedSpeech = false
        recordingURL = nil

        let session = AVAudioSession.sharedInstance()

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            print("[AudioRecorder] Microphone permission denied")
            #if os(watchOS)
            lastError = "Microphone access denied. Open Settings on your Apple Watch → Privacy → Microphone and enable WatchAI."
            #else
            lastError = "Microphone access denied. Open Settings → Privacy → Microphone and enable WatchAI."
            #endif
            return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.lastError = "Microphone permission is required to record."
                    }
                }
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        do {
            #if os(iOS)
            try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            #else
            try session.setCategory(.playAndRecord, mode: .default)
            #endif
            try session.setActive(true)
        } catch {
            print("[AudioRecorder] Failed to configure audio session: \(error)")
            lastError = "Mic session error: \(error.localizedDescription)"
            return
        }

        let fileName = "recording_\(UUID().uuidString).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            isRecording = true
            startSilenceDetection()
        } catch {
            print("[AudioRecorder] Failed to start recording: \(error)")
            lastError = "Recording error: \(error.localizedDescription)"
        }
    }

    func stopRecording() -> URL? {
        stopSilenceDetection()
        recorder?.stop()
        isRecording = false
        return recordingURL
    }

    // MARK: - Silence detection

    private func startSilenceDetection() {
        var silentSince: Date?

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.recorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)

            if power > self.silenceThreshold {
                // Sound detected
                self.hasDetectedSpeech = true
                silentSince = nil
            } else if self.hasDetectedSpeech {
                // Silence after speech
                if silentSince == nil {
                    silentSince = Date()
                } else if Date().timeIntervalSince(silentSince!) >= self.silenceTimeout {
                    DispatchQueue.main.async {
                        self.silenceDetected = true
                    }
                    self.stopSilenceDetection()
                }
            }
        }
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}
