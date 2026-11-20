import AVFoundation
import Foundation

/// In-app music preview (AD-15 scope: verify downloads, not a music player).
/// Wraps AVPlayer with plain observable state; detects corrupt/undecodable
/// files via item status + failed-to-play-end notifications, and marks a file
/// verified once playback actually advances.
@MainActor
@Observable
final class PreviewPlayer {
    enum Status: Equatable {
        case loading
        case ready(duration: Double) // seconds; -1 when unknown
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    /// Playback advanced past the start — the file decodes cleanly.
    private(set) var verified = false

    var duration: Double {
        if case .ready(let d) = status { return d }
        return 0
    }

    /// Formats AVFoundation can decode. OGG/WMA/APE/WV have no decoder here.
    static let supportedExtensions: Set<String> = [
        "mp3", "flac", "wav", "m4a", "aac", "alac", "aiff", "aif", "caf", "mp4",
    ]

    private var player: AVPlayer?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObs: NSObjectProtocol?

    func load(_ url: URL) {
        stop()
        status = .loading
        verified = false
        currentTime = 0
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            status = .failed("Preview can't decode .\(ext) files. That doesn't mean the file is corrupt — try a dedicated player for this format.")
            return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p

        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .failed:
                    self.status = .failed("Couldn't play this file — it may be corrupted or an incomplete download.")
                    self.isPlaying = false
                case .readyToPlay:
                    let d = item.duration.seconds
                    if case .failed = self.status { return }
                    self.status = .ready(duration: d.isFinite ? d : -1)
                default:
                    break
                }
            }
        }
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.status = .failed("Playback failed partway through — the file may be corrupted.")
                self?.isPlaying = false
            }
        }
        rateObs = p.observe(\.rate, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.isPlaying = p.rate > 0 }
        }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let s = time.seconds
                if s.isFinite { self.currentTime = s }
                if s > 0.3 && self.isPlaying { self.verified = true }
            }
        }
    }

    func playPause() {
        guard let p = player, case .ready = status else { return }
        if p.rate > 0 { p.pause() } else { p.play() }
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        p.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) {
        let target = currentTime + delta
        seek(to: duration > 0 ? min(max(0, target), duration) : max(0, target))
    }

    func stop() {
        if let timeObserver, let p = player { p.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObs = nil
        rateObs = nil
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        endObs = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}