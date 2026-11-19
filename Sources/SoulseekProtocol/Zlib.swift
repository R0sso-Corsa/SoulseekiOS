import Foundation
import zlib

/// zlib (RFC1950) wrappers over the system libz. Soulseek compresses whole
/// PeerSearchReply / share-list payloads with zlib.
public enum Zlib {
    public enum ZlibError: Error {
        case initFailed
        case streamFailed(Int32)
        case truncated
        case tooLarge
    }

    public static func inflate(_ data: Data, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZlibError.initFailed
        }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var result = Data()
        let chunkSize = 65536
        var output = [UInt8](repeating: 0, count: chunkSize)

        return try input.withUnsafeMutableBufferPointer { inBuf -> Data in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = UInt32(inBuf.count)
            while true {
                let status: Int32 = output.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let s = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { result.append(contentsOf: outBuf[0..<produced]) }
                    return s
                }
                if result.count > limit { throw ZlibError.tooLarge }
                if status == Z_STREAM_END { return result }
                if status != Z_OK { throw ZlibError.streamFailed(status) }
                if stream.avail_in == 0 { throw ZlibError.truncated }
            }
        }
    }

    public static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZlibError.initFailed
        }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var result = Data()
        let chunkSize = 65536
        var output = [UInt8](repeating: 0, count: chunkSize)

        return try input.withUnsafeMutableBufferPointer { inBuf -> Data in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = UInt32(inBuf.count)
            while true {
                let status: Int32 = output.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let s = zlib.deflate(&stream, Z_FINISH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { result.append(contentsOf: outBuf[0..<produced]) }
                    return s
                }
                if status == Z_STREAM_END { return result }
                if status != Z_OK { throw ZlibError.streamFailed(status) }
            }
        }
    }
}