import Foundation
import Darwin
import SoulseekProtocol

// M0 spike: connect to the Soulseek login server, send Login, decode the
// response and the post-login message burst. Credentials come from the
// environment only — never stored in this repo.

let env = ProcessInfo.processInfo.environment
guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
    FileHandle.standardError.write(Data("usage: SLSK_USER=<name> SLSK_PASS=<pw> slsk-spike [host] [port]\n".utf8))
    exit(1)
}
let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "server.slsknet.org"
let port = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "2242"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
}

// Resolve + connect (blocking; IPv4 or IPv6).
var hints = addrinfo()
hints.ai_family = AF_UNSPEC
hints.ai_socktype = SOCK_STREAM
var res: UnsafeMutablePointer<addrinfo>?
let rc = getaddrinfo(host, port, &hints, &res)
guard rc == 0, let first = res else { die("getaddrinfo: \(String(cString: gai_strerror(rc)))") }
defer { freeaddrinfo(res) }

var fd: Int32 = -1
var cur: UnsafeMutablePointer<addrinfo>? = first
var lastErr: Int32 = 0
while let a = cur {
    fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
    if fd >= 0 {
        if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { break }
        lastErr = errno
        close(fd)
        fd = -1
    } else {
        lastErr = errno
    }
    cur = a.pointee.ai_next
}
guard fd >= 0 else { die("connect: \(String(cString: strerror(lastErr)))") }

var tv = timeval(tv_sec: 4, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

print("connected to \(host):\(port)")
let login = Login.frame(username: user, password: pass)
print("sending Login (code 1): \(login.count) bytes, user=\(user), clientVersion=\(Login.clientVersion)")
var sent = 0
while sent < login.count {
    let n = login.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!.advanced(by: sent), login.count - sent, 0)
    }
    if n <= 0 { die("send: \(String(cString: strerror(errno)))") }
    sent += n
}

// Names confirmed against the aioslsk message index; anything else prints as ?.
let names: [UInt32: String] = [
    1: "Login", 5: "AddUser", 7: "GetUserStatus", 16: "UserJoinedRoom",
    36: "GetUserStats", 64: "RoomList", 69: "PrivilegedUsers",
    83: "ParentMinSpeed", 84: "ParentSpeedRatio", 86: "ParentInactivityTimeout",
    87: "SearchInactivityTimeout", 88: "MinParentsInCache",
    89: "DistributedDistributeInterval", 90: "DistributedAliveInterval",
    102: "PotentialParents", 104: "WishlistInterval",
]

var reader = FrameReader()
var buf = [UInt8](repeating: 0, count: 65536)
var gotLogin = false
var loginOK = false
var frames = 0
let deadline = Date().addingTimeInterval(12)

do {
    while Date() < deadline && frames < 200 {
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { break } // quiet socket: burst is over
            die("recv: \(String(cString: strerror(errno)))")
        }
        if n == 0 {
            print("server closed connection")
            break
        }
        reader.append(Data(buf[0..<n]))
        while let frame = try reader.next() {
            frames += 1
            if frame.code == 1 {
                let resp = try LoginResponse(payload: frame.payload)
                gotLogin = true
                loginOK = resp.success
                if resp.success {
                    print("LOGIN OK")
                    print("  greeting: \(resp.greeting ?? "")")
                    print("  our public IP (server's view): \(resp.ip ?? "?")")
                    print("  privileged: \(resp.privileged ?? false)")
                } else {
                    print("LOGIN FAILED: \(resp.reason ?? "?")")
                }
            } else {
                let hex = frame.payload.prefix(48).map { String(format: "%02x", $0) }.joined()
                let tail = frame.payload.count > 48 ? "…" : ""
                print("frame code=\(frame.code) (\(names[frame.code] ?? "?")) payload=\(frame.payload.count)B hex=\(hex)\(tail)")
            }
        }
    }
} catch {
    die("codec: \(error)")
}
close(fd)
print("total frames: \(frames)")
guard gotLogin else { die("no login response received") }
exit(loginOK ? 0 : 3)