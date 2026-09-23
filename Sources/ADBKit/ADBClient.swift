import Foundation

/// Client for the adb server's "smart socket" protocol (tcp:5037). Every
/// request runs on its own connection, as the protocol requires. Talking to
/// the server directly avoids spawning an `adb` process per command and works
/// with whatever adb version the user already has running.
public struct ADBClient: Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 5037) {
        self.host = host
        self.port = port
    }

    // MARK: Host services

    /// Starts the adb server if nothing answers on the port.
    public func ensureServerRunning() throws {
        if (try? serverVersion()) != nil { return }
        try ADBServerLauncher.startServer()
        _ = try serverVersion()
    }

    public func serverVersion() throws -> Int {
        let socket = try connect()
        defer { socket.close() }
        try send("host:version", on: socket)
        let text = try readLengthPrefixed(socket)
        guard let version = Int(text, radix: 16) else {
            throw ADBError.protocolViolation("bad server version '\(text)'")
        }
        return version
    }

    public func devices() throws -> [ADBDevice] {
        let socket = try connect()
        defer { socket.close() }
        try send("host:devices-l", on: socket)
        return ADBDevice.parseList(try readLengthPrefixed(socket))
    }

    /// Blocks, calling `onChange` with the full device list now and after every
    /// plug / unplug / authorization change, until it returns false.
    public func trackDevices(_ onChange: ([ADBDevice]) -> Bool) throws {
        let socket = try connect()
        defer { socket.close() }
        try send("host:track-devices-l", on: socket)
        while onChange(ADBDevice.parseList(try readLengthPrefixed(socket))) {}
    }

    // MARK: Device services

    /// Opens a device service (`shell:…`, `exec:…`, `sync:`, `localabstract:…`).
    /// On return the socket is a raw pipe to that service.
    public func openService(serial: String, _ service: String) throws -> TCPSocket {
        let socket = try connect()
        do {
            try send("host:transport:\(serial)", on: socket)
            try send(service, on: socket)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// Runs a command without a pty and returns its raw output; binary safe,
    /// unlike `shell:`, whose pty rewrites line endings.
    public func exec(serial: String, _ command: String) throws -> Data {
        let socket = try openService(serial: serial, "exec:\(command)")
        defer { socket.close() }
        var output = Data()
        while true {
            let chunk = try socket.read(upTo: 64 * 1024)
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        return output
    }

    /// Runs a command and returns everything it printed.
    public func run(serial: String, _ command: String) throws -> String {
        String(decoding: try exec(serial: serial, command), as: UTF8.self)
    }

    public func push(serial: String, data: Data, to remotePath: String, mode: UInt32 = 0o644) throws {
        let socket = try openService(serial: serial, "sync:")
        defer { socket.close() }

        var message = ADBWire.syncSend(remotePath: remotePath, mode: mode)
        var offset = 0
        while offset < data.count {
            let end = min(offset + ADBWire.syncDataMax, data.count)
            message += ADBWire.syncHeader("DATA", UInt32(end - offset))
            message += data[(data.startIndex + offset)..<(data.startIndex + end)]
            offset = end
        }
        message += ADBWire.syncHeader("DONE", UInt32(Date().timeIntervalSince1970))
        try socket.writeAll(message)

        let reply = [UInt8](try socket.readExactly(8))
        let status = String(decoding: reply[0..<4], as: UTF8.self)
        guard status != "OKAY" else { return }
        let length = Int(reply[4]) | Int(reply[5]) << 8 | Int(reply[6]) << 16 | Int(reply[7]) << 24
        let detail = status == "FAIL" ? String(decoding: try socket.readExactly(length), as: UTF8.self) : status
        throw ADBError.requestFailed(request: "push \(remotePath)", message: detail)
    }

    // MARK: Wi-Fi

    /// Asks the adb server to connect to a device listening on TCP
    /// (`ip:port`, port 5555 by default). The reply is the server's own
    /// wording ("connected to …", "already connected …", or a failure).
    @discardableResult
    public func connect(address: String) throws -> String {
        let reply = try hostReply("host:connect:\(Self.withPort(address))")
        guard reply.hasPrefix("connected") || reply.hasPrefix("already connected") else {
            throw ADBError.requestFailed(request: "connect \(address)", message: reply)
        }
        return reply
    }

    @discardableResult
    public func disconnect(address: String) throws -> String {
        try hostReply("host:disconnect:\(Self.withPort(address))")
    }

    /// Android 11+ wireless debugging: the phone shows an address and a
    /// six-digit code under Settings › Developer options › Wireless debugging.
    @discardableResult
    public func pair(address: String, code: String) throws -> String {
        let reply = try hostReply("host:pair:\(code):\(address)")
        guard reply.hasPrefix("Successfully paired") else {
            throw ADBError.requestFailed(request: "pair \(address)", message: reply)
        }
        return reply
    }

    /// Restarts the device's adbd listening on TCP. The USB session stays;
    /// the device then also accepts `connect(address:)` on its Wi-Fi address.
    public func enableTCP(serial: String, port: Int = 5555) throws {
        let socket = try openService(serial: serial, "tcpip:\(port)")
        defer { socket.close() }
        let reply = String(decoding: try socket.read(upTo: 256), as: UTF8.self)
        guard reply.contains("restarting") else {
            throw ADBError.requestFailed(request: "tcpip \(port)", message: reply)
        }
    }

    /// The device's Wi-Fi IPv4 address, or nil when it is not on Wi-Fi.
    public func wifiAddress(serial: String) throws -> String? {
        let output = try run(serial: serial, "ip -o -4 addr show scope global")
        // Lines like: "24: wlan0    inet 192.168.1.42/24 brd … scope global wlan0"
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[1].hasPrefix("wlan") || fields[1].hasPrefix("swlan") else { continue }
            return String(fields[3].split(separator: "/")[0])
        }
        return nil
    }

    /// Devices the adb server has discovered on the local network:
    /// `_adb._tcp` (adbd in tcpip mode) and `_adb-tls-connect._tcp`
    /// (Android 11+ wireless debugging, whose port changes every session).
    public struct MDNSService: Equatable, Sendable {
        public let name: String
        public let type: String
        public let address: String
    }

    public func mdnsServices() throws -> [MDNSService] {
        try hostReply("host:mdns:services").split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 3 else { return nil }
            return MDNSService(name: fields[0], type: fields[1], address: fields[2])
        }
    }

    /// True when something accepts TCP connections at `ip:port` within
    /// `timeout`. The adb server itself waits 75 s on a dead address.
    public static func isReachable(_ address: String, timeout: TimeInterval = 1.5) -> Bool {
        let full = withPort(address)
        guard let colon = full.lastIndex(of: ":"), let port = UInt16(full[full.index(after: colon)...]) else { return false }
        let host = String(full[..<colon])
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }
        let fd = socket(first.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&writable, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0
    }

    public static func withPort(_ address: String) -> String {
        address.contains(":") ? address : address + ":5555"
    }

    /// Host services that answer OKAY then a length-prefixed text.
    private func hostReply(_ request: String) throws -> String {
        let socket = try connect()
        defer { socket.close() }
        try send(request, on: socket)
        return try readLengthPrefixed(socket).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Wire helpers

    private func connect() throws -> TCPSocket {
        do {
            return try TCPSocket(host: host, port: port)
        } catch {
            throw ADBError.serverUnreachable("\(host):\(port) (\(error))")
        }
    }

    private func send(_ request: String, on socket: TCPSocket) throws {
        try socket.writeAll(ADBWire.request(request))
        let status = String(decoding: try socket.readExactly(4), as: UTF8.self)
        switch status {
        case "OKAY":
            return
        case "FAIL":
            throw ADBError.requestFailed(request: request, message: try readLengthPrefixed(socket))
        default:
            throw ADBError.protocolViolation("unexpected status '\(status)' for '\(request)'")
        }
    }

    private func readLengthPrefixed(_ socket: TCPSocket) throws -> String {
        let length = try ADBWire.parseHexLength(try socket.readExactly(4))
        return String(decoding: try socket.readExactly(length), as: UTF8.self)
    }
}
