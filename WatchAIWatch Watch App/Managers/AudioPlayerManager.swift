import AVFoundation
import Combine

final class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var lastError: String?

    private var audioPlayer: AVAudioPlayer?

    func play(url: URL) {
        stop()
        lastError = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("[AudioPlayer] Failed to configure audio session: \(error)")
            lastError = "Audio session error: \(error.localizedDescription)"
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
        } catch {
            print("[AudioPlayer] Failed to play: \(error)")
            lastError = "Playback error: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            if !flag {
                self.lastError = "Playback finished unsuccessfully"
            }
        }
    }
}
