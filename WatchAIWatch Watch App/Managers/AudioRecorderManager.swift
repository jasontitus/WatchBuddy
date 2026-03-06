import AVFoundation
import Combine

final class AudioRecorderManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private(set) var recordingURL: URL?

    func startRecording() {
        lastError = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
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
            recorder?.record()
            isRecording = true
        } catch {
            print("[AudioRecorder] Failed to start recording: \(error)")
            lastError = "Recording error: \(error.localizedDescription)"
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        isRecording = false
        return recordingURL
    }
}
