import Foundation

/// Server-bound message encoders. Field order verified against the rendered
/// aioslsk MESSAGES docs (2026-11-18), not memory.
public enum ServerMessages {
    /// Code 2. port + obfuscated_port_amount + obfuscated_port; zeros = no obfuscation.
    /// Port 0 advertises "no listening port" (receive-only client until a listener exists).
    public static func setListenPort(_ port: UInt32, obfuscatedPort: UInt32 = 0) -> Data {
        var w = MessageWriter()
        w.u32(port)
        w.u32(obfuscatedPort == 0 ? 0 : 1)
        w.u32(obfuscatedPort)
        return w.frame(code: 2)
    }

    /// Code 5. Server replies with exists/status/stats; adds us to our own buddy list.
    public static func addUser(_ username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 5)
    }

    /// Code 28. 0 = offline, 1 = away, 2 = online.
    public static func setStatus(_ status: UInt32) -> Data {
        var w = MessageWriter()
        w.u32(status)
        return w.frame(code: 28)
    }

    /// Code 32. Keepalive, every 5 minutes. No parameters.
    public static func ping() -> Data {
        MessageWriter().frame(code: 32)
    }

    /// Code 35. Folder count FIRST, then file count.
    public static func sharedFoldersFiles(folders: UInt32, files: UInt32) -> Data {
        var w = MessageWriter()
        w.u32(folders)
        w.u32(files)
        return w.frame(code: 35)
    }

    /// Code 71. Whether the server should send us PotentialParents.
    public static func toggleParentSearch(_ enable: Bool) -> Data {
        var w = MessageWriter()
        w.u8(enable ? 1 : 0)
        return w.frame(code: 71)
    }

    /// Code 92. No parameters; reply carries time_left (u32 seconds).
    public static func checkPrivileges() -> Data {
        MessageWriter().frame(code: 92)
    }

    /// Code 100. Whether we accept distributed children.
    public static func acceptChildren(_ accept: Bool) -> Data {
        var w = MessageWriter()
        w.u8(accept ? 1 : 0)
        return w.frame(code: 100)
    }

    /// Code 126.
    public static func branchLevel(_ level: UInt32) -> Data {
        var w = MessageWriter()
        w.u32(level)
        return w.frame(code: 126)
    }

    /// Code 127.
    public static func branchRoot(_ username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 127)
    }

    /// Code 26. Global search: ticket + query. Results arrive asynchronously
    /// as PeerSearchReply(9) on peer connections.
    public static func fileSearch(ticket: UInt32, query: String) -> Data {
        var w = MessageWriter()
        w.u32(ticket)
        w.string(query)
        return w.frame(code: 26)
    }

    /// Code 1001. Report a failed indirect connection attempt back to the server.
    public static func cannotConnect(ticket: UInt32, username: String) -> Data {
        var w = MessageWriter()
        w.u32(ticket)
        w.string(username)
        return w.frame(code: 1001)
    }

    /// Code 3. Resolve a peer's address; reply carries ip/port (0.0.0.0/0 = offline).
    public static func getPeerAddress(username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 3)
    }

    /// Code 36. Request a user's upload stats (reply: UserStats).
    public static func getUserStats(username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 36)
    }

    /// Code 7. Request a user's online/away status (reply: UserStatus).
    public static func getUserStatus(username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 7)
    }
}

/// Post-login handshake for a receive-only client (AD-5): no listener yet,
/// no shares, no distributed participation. Order per aioslsk logon flow.
public enum Handshake {
    public static func frames(username: String) -> [Data] {
        [
            ServerMessages.checkPrivileges(),
            ServerMessages.setListenPort(0),
            ServerMessages.setStatus(2),
            ServerMessages.sharedFoldersFiles(folders: 0, files: 0),
            ServerMessages.addUser(username),
            ServerMessages.toggleParentSearch(false),
            ServerMessages.branchRoot(username),
            ServerMessages.branchLevel(0),
            ServerMessages.acceptChildren(false),
        ]
    }
}