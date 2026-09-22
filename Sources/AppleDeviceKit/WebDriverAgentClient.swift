import Darwin
import Foundation

/// Minimal HTTP/1.1 client for WebDriverAgent's server on the phone, over a
/// usbmuxd socket. One request per connection keeps it simple and lets
/// requests come from any thread.
public struct WebDriverAgentClient: Sendable {
    public let udid: String
    public let port: UInt16

    public enum Error: Swift.Error, CustomStringConvertible {
        case badResponse(String)
        case http(status: Int, body: String)
        case wda(String)

        public var description: String {
            switch self {
            case .badResponse(let detail): return "WebDriverAgent: bad response (\(detail))"
            case .http(let status, let body): return "WebDriverAgent: HTTP \(status): \(body.prefix(200))"
            case .wda(let message): return "WebDriverAgent: \(message)"
            }
        }
    }

    public init(udid: String, port: UInt16 = 8100) {
        self.udid = udid
        self.port = port
    }

    /// `GET /status`: nil unless a server answers.
    public func status() -> [String: Any]? {
        (try? call("GET", "/status"))?["value"] as? [String: Any]
    }

    /// Creates a session and returns its id. No app is named: gestures then
    /// go to whatever is in front. (Naming SpringBoard makes WebDriverAgent
    /// try to launch it, which fails.)
    public func createSession() throws -> String {
        let reply = try call("POST", "/session", ["capabilities": ["alwaysMatch": [:]]])
        guard let value = reply["value"] as? [String: Any], let id = value["sessionId"] as? String
                ?? reply["sessionId"] as? String else {
            throw Error.badResponse("no sessionId")
        }
        return id
    }

    /// Trims what WebDriverAgent does around each action: no waiting for the
    /// front app to go idle (up to 2 s of animation), and no accessibility
    /// snapshot of it (`snapshotMaxDepth` 0 halved a tap, 1.0 → 0.43 s).
    /// Coordinates-only gestures need neither.
    public func tuneForLowLatency(session: String) throws {
        _ = try call("POST", "/session/\(session)/appium/settings", ["settings": [
            "waitForIdleTimeout": 0, "animationCoolOffTimeout": 0, "snapshotMaxDepth": 0,
        ]])
    }

    /// Points per pixel is 1 / scale (3 on a Plus / Max phone). The window
    /// size is not asked for: it needs an app attached to the session.
    public func screenScale(session: String) throws -> Double {
        let reply = try call("GET", "/session/\(session)/wda/screen")
        guard let value = reply["value"] as? [String: Any], let scale = value["scale"] as? Double, scale > 0 else {
            throw Error.badResponse("no screen scale")
        }
        return scale
    }

    /// W3C pointer actions with a touch pointer. Points are in screen points.
    public func performTouch(session: String, actions: [[String: Any]]) throws {
        try performTouch(session: session, encodedActions: try Self.encodeTouch(actions))
    }

    /// `encodeTouch` output; Data crosses threads where `[String: Any]` cannot.
    public func performTouch(session: String, encodedActions: Data) throws {
        _ = try call("POST", "/session/\(session)/actions", body: encodedActions)
    }

    public static func encodeTouch(_ actions: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["actions": [[
            "type": "pointer", "id": "finger1", "parameters": ["pointerType": "touch"], "actions": actions,
        ]]])
    }

    /// `home`, `volumeUp`, `volumeDown`, `lock` (power).
    public func pressButton(session: String, _ name: String) throws {
        _ = try call("POST", "/session/\(session)/wda/pressButton", ["name": name])
    }

    public func type(session: String, _ text: String) throws {
        _ = try call("POST", "/session/\(session)/wda/keys", ["value": text.map { String($0) }])
    }

    // MARK: HTTP

    @discardableResult
    func call(_ method: String, _ path: String, _ json: [String: Any]? = nil) throws -> [String: Any] {
        try call(method, path, body: json.map { try JSONSerialization.data(withJSONObject: $0) })
    }

    @discardableResult
    func call(_ method: String, _ path: String, body: Data?) throws -> [String: Any] {
        let fd = try USBMuxClient.connect(udid: udid, port: port)
        defer { close(fd) }
        let payload = body ?? Data()
        var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if body != nil { request += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n" }
        request += "\r\n"
        try write(fd, Data(request.utf8) + payload)

        // WebDriverAgent keeps the connection open whatever the request says,
        // so the body length comes from the header, not from end of stream.
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var expectedTotal: Int?
        while expectedTotal.map({ response.count < $0 }) ?? true {
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { break }
            response.append(buffer, count: received)
            if expectedTotal == nil, let split = response.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").lazy
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                expectedTotal = split.upperBound + length
            }
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw Error.badResponse("no header") }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
        let bodyData = response[split.upperBound...]
        let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["value"] as? [String: Any])?["message"] as? String
                ?? String(decoding: bodyData, as: UTF8.self)
            throw Error.http(status: status, body: message)
        }
        if let value = json["value"] as? [String: Any], let error = value["error"] as? String {
            throw Error.wda(value["message"] as? String ?? error)
        }
        return json
    }

    private func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                guard sent > 0 else { throw Error.badResponse("send failed") }
                offset += sent
            }
        }
    }
}
