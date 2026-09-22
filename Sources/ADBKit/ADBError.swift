import Foundation

public enum ADBError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening on the adb server port and it could not be started.
    case serverUnreachable(String)
    case adbBinaryNotFound
    case socket(operation: String, code: Int32)
    case endOfStream
    case protocolViolation(String)
    /// The adb server (or the device) answered FAIL to a request.
    case requestFailed(request: String, message: String)

    public var description: String {
        switch self {
        case .serverUnreachable(let detail):
            return "adb server unreachable: \(detail)"
        case .adbBinaryNotFound:
            return "adb binary not found (set ADB_PATH or ANDROID_HOME)"
        case .socket(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .endOfStream:
            return "connection closed"
        case .protocolViolation(let detail):
            return "adb protocol violation: \(detail)"
        case .requestFailed(let request, let message):
            return "adb request '\(request)' failed: \(message)"
        }
    }
}
