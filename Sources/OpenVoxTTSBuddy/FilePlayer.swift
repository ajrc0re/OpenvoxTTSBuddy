import AVFoundation
import Combine

/// Plays a finished clip with play/pause, seeking and volume.
@MainActor
final class FilePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0

    /// While the user drags the position slider, the timer leaves it alone.
    var isScrubbing = false

    var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ data: Data) throws {
        stop()
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        newPlayer.volume = volume
        newPlayer.prepareToPlay()
        player = newPlayer
        duration = newPlayer.duration
        currentTime = 0
        isLoaded = true
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.01 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, !isScrubbing else { return }
        currentTime = player.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = self.duration
        }
    }
}
