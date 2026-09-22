import Foundation

/// Finds an `adb` binary and starts its server. Only needed when no adb server
/// is running yet; an already-running server (e.g. Android Studio's) is reused
/// as is, which avoids the "server version mismatch, killing" dance.
public enum ADBServerLauncher {
    public static func locateADB(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []
        if let explicit = environment["ADB_PATH"] { candidates.append(explicit) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key] { candidates.append("\(sdk)/platform-tools/adb") }
        }
        candidates.append("\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb")
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func startServer() throws {
        guard let adb = locateADB() else { throw ADBError.adbBinaryNotFound }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["start-server"]
        // The daemon inherits these; a pipe here would never reach EOF.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ADBError.serverUnreachable("'\(adb.path) start-server' exited with \(process.terminationStatus)")
        }
    }
}
