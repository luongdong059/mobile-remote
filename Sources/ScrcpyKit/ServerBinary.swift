import CryptoKit
import Foundation

enum ServerBinary {
    /// The bundled scrcpy-server, checked against the pinned digest so a
    /// damaged or swapped file is never pushed to a phone.
    static func load() throws -> Data {
        // Inside an .app the file sits in Contents/Resources. `Bundle.module`
        // only knows the build directory and traps when that is gone, so it is
        // the fallback for `swift run` and tests.
        let name = ScrcpyProtocol.serverResourceName
        guard let url = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            throw ScrcpyError.serverBinaryMissing
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == ScrcpyProtocol.serverSHA256 else {
            throw ScrcpyError.serverBinaryCorrupted(sha256: digest)
        }
        return data
    }
}
