import Foundation

/// WishlistSearch (server 103): token + query, same shape as FileSearch but
/// flagged as a wishlist search by the server.
public struct WishlistInterval: Equatable, Sendable {
    public let seconds: UInt32

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        seconds = try r.u32()
    }
}