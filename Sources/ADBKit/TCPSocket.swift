import Darwin
import Foundation

/// Anything bytes can be pulled from in exact amounts; lets stream parsers be
/// tested without a socket.
public protocol ByteSource {
    func readExactly(_ count: Int) throws -> Data
}

/// Blocking TCP socket. Streams are read on dedicated threads, so blocking I/O
/// keeps latency low and the code simple. `close()` may be called from any
/// thread to unblock a pending read.
public final class TCPSocket: ByteSource, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init(host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBError.socket(operation: "socket", code: errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw ADBError.protocolViolation("invalid IPv4 address '\(host)'")
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ADBError.socket(operation: "connect", code: code)
        }

        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        self.fd = fd
    }

    deinit {
        close()
        // Released only here: closing the descriptor while another thread is
        // still blocked on it would let the number be reused under its feet.
        Darwin.close(fd)
    }

    public func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = recv(fd, buffer.baseAddress! + offset, count - offset, 0)
                if received > 0 {
                    offset += received
                } else if received == 0 {
                    throw ADBError.endOfStream
                } else if errno != EINTR {
                    throw ADBError.socket(operation: "recv", code: errno)
                }
            }
        }
        return data
    }

    /// Returns empty data at end of stream.
    public func read(upTo maxCount: Int) throws -> Data {
        var data = Data(count: maxCount)
        let received: Int = try data.withUnsafeMutableBytes { buffer in
            while true {
                let received = recv(fd, buffer.baseAddress!, maxCount, 0)
                if received >= 0 { return received }
                if errno != EINTR { throw ADBError.socket(operation: "recv", code: errno) }
            }
        }
        data.count = received
        return data
    }

    public func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if errno != EINTR {
                    throw ADBError.socket(operation: "send", code: errno)
                }
            }
        }
    }

    /// Ends the connection and wakes any thread blocked in a read.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
    }
}
