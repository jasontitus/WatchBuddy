import AVFoundation
import Combine

final class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false

    private var player: AVPlayer?
    private var playerObserver: Any?

    func play(url: URL) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("[AudioPlayer] Failed to configure audio session: \(error)")
            return
        }

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }

        isPlaying = true
        player?.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
            playerObserver = nil
        }
        isPlaying = false
    }
}
