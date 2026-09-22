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
