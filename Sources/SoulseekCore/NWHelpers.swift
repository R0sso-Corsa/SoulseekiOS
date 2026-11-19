import Foundation
import Network

/// NWConnection is thread-safe (Network.framework) but not annotated Sendable.
/// This box lets links cross actor boundaries under Swift 6 region isolation.
public struct PeerLink: @unchecked Sendable {
    public let connection: NWConnection
    public init(_ connection: NWConnection) {
        self.connection = connection
    }
}

/// Shared NWConnection bridges (actor callers hop back via await).
/// Extraction per AD-11; ServerConnection/SearchEngine keep their inline
/// copies until the full PeerConnections refactor.

func nwWaitReady(_ conn: NWConnection, timeout: UInt64 = 10_000_000_000) async -> Bool {
    await withCheckedContinuation { cont in
        let once = OnceFlag()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                once.fire { cont.resume(returning: true) }
            case .failed, .cancelled:
                once.fire { cont.resume(returning: false) }
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "slsk.peer.dial"))
        Task {
            try? await Task.sleep(nanoseconds: timeout)
            once.fire { cont.resume(returning: false) }
        }
    }
}

func nwSend(_ conn: NWConnection, data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        })
    }
}

func nwReceiveChunk(_ conn: NWConnection) async -> Data? {
    await withCheckedContinuation { cont in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if error != nil || data == nil || data!.isEmpty {
                cont.resume(returning: nil)
            } else {
                cont.resume(returning: data)
            }
        }
    }
}