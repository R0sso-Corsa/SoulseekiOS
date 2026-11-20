import Foundation
import SoulseekCore
import SoulseekProtocol

/// Drives chat-media attachments (AD-16): checks local copies first (own
/// sends + previously received), otherwise fetches via TransferEngine into
/// the received-media directory and tracks progress for the bubble UI.
@MainActor
@Observable
final class MediaStore {
    enum State: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
        case needsTap
    }

    private(set) var states: [String: State] = [:]

    private let transfers: TransferEngine
    private let receivedDir: URL
    private let sentDir: URL
    private var task: Task<Void, Never>?

    init(transfers: TransferEngine, receivedDir: URL, sentDir: URL) {
        self.transfers = transfers
        self.receivedDir = receivedDir
        self.sentDir = sentDir
        task = Task { [weak self] in
            guard let stream = self?.transfers.updates else { return }
            for await list in stream {
                guard let self else { return }
                for t in list where t.isMedia {
                    let k = Self.key(username: t.username, path: t.filename)
                    switch t.state {
                    case .completed:
                        if let p = t.localPath {
                            self.states[k] = .ready(URL(fileURLWithPath: p))
                        }
                    case .failed(let reason):
                        self.states[k] = .failed(reason)
                    case .cancelled:
                        self.states[k] = .idle
                    default:
                        break
                    }
                }
            }
        }
    }

    static func key(username: String, path: String) -> String { username + "|" + path }
    static func key(_ card: MediaCard) -> String { key(username: card.username, path: card.path) }

    private static func sanitized(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    func state(for card: MediaCard) -> State { states[Self.key(card)] ?? .idle }

    /// Resolve a card: local copy → ready; else start (or offer) the fetch.
    func ensure(_ card: MediaCard, allowCellular: Bool) {
        let k = Self.key(card)
        if case .ready = states[k] { return }
        if case .downloading = states[k] { return }
        let name = Self.sanitized(card.path)
        // Soulseek paths are Windows-style — NSString path APIs don't split
        // on backslashes, so extract the basename manually.
        let base = card.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? card.path
        // Sent files are stored by basename; received files by the
        // transfer engine's sanitized full path.
        let candidates = [
            sentDir.appendingPathComponent(base),
            sentDir.appendingPathComponent(name),
            receivedDir.appendingPathComponent(name),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                states[k] = .ready(url)
                return
            }
        }
        if !allowCellular {
            states[k] = .needsTap
            return
        }
        start(card)
    }

    func start(_ card: MediaCard) {
        states[Self.key(card)] = .downloading
        Task { await transfers.downloadMedia(username: card.username, filename: card.path, size: card.size) }
    }
}