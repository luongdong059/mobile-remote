import Foundation

public struct ADBDevice: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case device
        case offline
        /// The phone is showing (or has dismissed) the "Allow USB debugging?" dialog.
        case unauthorized
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "device": self = .device
            case "offline": self = .offline
            case "unauthorized": self = .unauthorized
            default: self = .other(raw)
            }
        }
    }

    public let serial: String
    public let state: State
    /// `product`, `model`, `device`, `transport_id` and, for cabled devices, `usb`.
    public let properties: [String: String]

    public init(serial: String, state: State, properties: [String: String] = [:]) {
        self.serial = serial
        self.state = state
        self.properties = properties
    }

    public var id: String { serial }
    public var model: String? { properties["model"]?.replacingOccurrences(of: "_", with: " ") }
    public var isUSB: Bool { properties["usb"] != nil }

    /// Parses the payload of `host:devices-l` / `host:track-devices-l`.
    static func parseList(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { return nil }
            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":") else { continue }
                properties[String(field[..<colon])] = String(field[field.index(after: colon)...])
            }
            return ADBDevice(serial: String(fields[0]), state: State(String(fields[1])), properties: properties)
        }
    }
}
