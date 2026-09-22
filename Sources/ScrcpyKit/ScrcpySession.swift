import ADBKit
import Foundation

/// A running scrcpy-server plus the sockets connected to it.
///
/// The server is started through a pty-backed `shell:` service, so dropping
/// that connection (including when this process dies) hangs the server up and
/// its own cleanup restores any device settings it changed.
public final class ScrcpySession: @unchecked Sendable {
    /// Seconds spent in each startup step.
    public struct Timeline: Sendable {
        public var push: TimeInterval = 0
        /// From launching the server to its first accepted connection.
        public var serverReady: TimeInterval = 0
    }

    public let serial: String
    public let options: ScrcpyServerOptions
    public let deviceName: String
    public let timeline: Timeline
    public let videoSocket: TCPSocket?
    public let audioSocket: TCPSocket?
    /// Read device messages from here; write only through `send(_:)`.
    public let controlSocket: TCPSocket?
    private let shellSocket: TCPSocket
    private let controlLock = NSLock()

    private static let connectAttempts = 100
    private static let connectRetryDelay: TimeInterval = 0.05

    private init(serial: String, options: ScrcpyServerOptions, deviceName: String, timeline: Timeline,
                 shellSocket: TCPSocket, sockets: [TCPSocket]) {
        self.serial = serial
        self.options = options
        self.deviceName = deviceName
        self.timeline = timeline
        self.shellSocket = shellSocket
        var remaining = sockets[...]
        videoSocket = options.video ? remaining.popFirst() : nil
        audioSocket = options.audio ? remaining.popFirst() : nil
        controlSocket = options.control ? remaining.popFirst() : nil
    }

    /// Pushes the server, launches it and connects every enabled stream.
    /// `onServerLog` receives the server's output lines on a background thread.
    public static func start(
        adb: ADBClient, serial: String, options: ScrcpyServerOptions,
        onServerLog: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> ScrcpySession {
        var timeline = Timeline()

        let binary = try ServerBinary.load()
        var mark = Date()
        try adb.push(serial: serial, data: binary, to: ScrcpyProtocol.remoteServerPath)
        timeline.push = Date().timeIntervalSince(mark)

        mark = Date()
        let shellSocket = try adb.openService(serial: serial, "shell:\(options.shellCommand())")
        let log = ServerLog()
        Thread.detachNewThread {
            log.drain(shellSocket, onLine: onServerLog)
        }

        var sockets: [TCPSocket] = []
        do {
            // Sockets must be opened in this order; the server accepts them one by one.
            let streamCount = [options.video, options.audio, options.control].filter { $0 }.count
            for index in 0..<streamCount {
                let socket = try connect(adb: adb, serial: serial, name: options.socketName, log: log)
                sockets.append(socket)
                if index == 0 {
                    // Forward-tunnel handshake: one dummy byte on the first socket.
                    _ = try socket.readExactly(1)
                    timeline.serverReady = Date().timeIntervalSince(mark)
                }
            }
            // Sent on the first socket once every stream is connected.
            let nameBytes = try sockets[0].readExactly(ScrcpyProtocol.deviceNameLength)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            return ScrcpySession(serial: serial, options: options, deviceName: name, timeline: timeline,
                                 shellSocket: shellSocket, sockets: sockets)
        } catch {
            sockets.forEach { $0.close() }
            shellSocket.close()
            throw error
        }
    }

    /// The abstract socket only exists once the server's JVM is up, so retry
    /// until the device accepts.
    private static func connect(adb: ADBClient, serial: String, name: String, log: ServerLog) throws -> TCPSocket {
        for _ in 0..<connectAttempts {
            do {
                return try adb.openService(serial: serial, "localabstract:\(name)")
            } catch ADBError.requestFailed {
                if log.hasEnded { throw ScrcpyError.serverExited(log: log.lines) }
                Thread.sleep(forTimeInterval: connectRetryDelay)
            }
        }
        throw ScrcpyError.connectTimeout(log: log.lines)
    }

    public func send(_ message: ControlMessage) throws {
        guard let controlSocket else { throw ScrcpyError.controlDisabled }
        controlLock.lock()
        defer { controlLock.unlock() }
        try controlSocket.writeAll(message.serialized())
    }

    /// Closes every connection; the server exits and cleans up after itself.
    public func stop() {
        videoSocket?.close()
        audioSocket?.close()
        controlSocket?.close()
        shellSocket.close()
    }

    deinit {
        stop()
    }
}

/// Collects the server's output from its shell connection.
private final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var ended = false

    var lines: [String] { lock.withLock { collected } }
    var hasEnded: Bool { lock.withLock { ended } }

    func drain(_ socket: TCPSocket, onLine: @Sendable (String) -> Void) {
        var pending = Data()
        while let chunk = try? socket.read(upTo: 4096), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pending = Data(pending[pending.index(after: newline)...])
                guard !line.isEmpty else { continue }
                lock.withLock { collected.append(line) }
                onLine(line)
            }
        }
        lock.withLock { ended = true }
    }
}
