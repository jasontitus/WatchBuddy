import AVFoundation
import Combine

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

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
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
