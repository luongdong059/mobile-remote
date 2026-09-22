import Darwin
import Foundation

/// Talks to usbmuxd, the daemon that multiplexes TCP over the USB cable to
/// iOS devices. `connect` yields a socket to a port on the phone, which is
/// how WebDriverAgent's HTTP server is reached without any network.
public enum USBMuxClient {
    public struct Device: Equatable, Sendable {
        public let id: Int
        /// The 40-char / 25-char device identifier (UDID).
        public let udid: String
        public let productID: Int
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case socket(String)
        case protocolViolation(String)
        case deviceNotFound(String)
        /// usbmuxd result number (3 = nothing listening on that port).
        case connectRefused(Int)

        public var description: String {
            switch self {
            case .socket(let detail): return "usbmuxd: \(detail)"
            case .protocolViolation(let detail): return "usbmuxd protocol: \(detail)"
            case .deviceNotFound(let udid): return "usbmuxd: no cabled device \(udid)"
            case .connectRefused(let code): return "usbmuxd: connect refused (\(code))"
            }
        }
    }

    static let socketPath = "/var/run/usbmuxd"

    public static func listDevices() throws -> [Device] {
        let socket = try open()
        defer { Darwin.close(socket) }
        let reply = try request(socket, ["MessageType": "ListDevices"])
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = entry["DeviceID"] as? Int, let props = entry["Properties"] as? [String: Any],
                  let udid = props["SerialNumber"] as? String, props["ConnectionType"] as? String == "USB" else { return nil }
            return Device(id: id, udid: udid, productID: props["ProductID"] as? Int ?? 0)
        }
    }

    /// A raw socket connected to `port` on the device. The caller owns it.
    public static func connect(udid: String, port: UInt16) throws -> Int32 {
        guard let device = try listDevices().first(where: { $0.udid == udid }) else {
            throw Error.deviceNotFound(udid)
        }
        let socket = try open()
        let reply: [String: Any]
        do {
            // Port is sent in network byte order inside the plist.
            reply = try request(socket, ["MessageType": "Connect", "DeviceID": device.id,
                                         "PortNumber": Int(port.bigEndian)])
        } catch {
            Darwin.close(socket)
            throw error
        }
        let number = reply["Number"] as? Int ?? -1
        guard number == 0 else {
            Darwin.close(socket)
            throw Error.connectRefused(number)
        }
        return socket
    }

    private static func open() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socket(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 104) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            throw Error.socket("connect \(socketPath): \(detail)")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// One plist request / reply. Header: length, version 1, type 8 (plist), tag.
    private static func request(_ fd: Int32, _ fields: [String: Any]) throws -> [String: Any] {
        var message = fields
        message["ClientVersionString"] = "mobile-remote"
        message["ProgName"] = "mobile-remote"
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        try writeAll(fd, packet)

        let header = try readExactly(fd, 16)
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(as: UInt32.self))) }
        guard length >= 16, length < 1 << 20 else { throw Error.protocolViolation("reply length \(length)") }
        let reply = try readExactly(fd, length - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: reply, format: nil) as? [String: Any] else {
            throw Error.protocolViolation("reply is not a dictionary")
        }
        return plist
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                guard sent > 0 else { throw Error.socket("send: \(String(cString: strerror(errno)))") }
                offset += sent
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = recv(fd, buffer.baseAddress! + offset, count - offset, 0)
                guard received > 0 else { throw Error.socket("recv: connection closed") }
                offset += received
            }
        }
        return data
    }
}
