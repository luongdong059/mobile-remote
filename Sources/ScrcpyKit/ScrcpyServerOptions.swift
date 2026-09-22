import Foundation

/// Options passed to scrcpy-server as `key=value` arguments. Only values that
/// differ from the server's own defaults are sent.
public struct ScrcpyServerOptions: Sendable {
    /// 31-bit session id; names the device-side socket `scrcpy_<scid as %08x>`.
    public var scid: UInt32
    public var logLevel = "info"
    public var video = true
    /// Off by default: measured at roughly +0.6 core on a mid-range phone.
    public var audio = false
    public var control = true
    public var videoCodec: StreamCodec = .h264
    /// Raw PCM needs no decoder on the Mac and costs ~1.5 Mbps over the cable.
    public var audioCodec: StreamCodec = .raw
    public var videoBitRate: Int?
    /// Longest side in pixels. Native resolution saturates mid-range encoders.
    public var maxSize: Int?
    public var maxFps: Int? = 60
    /// Wake the screen when the session starts.
    public var powerOn = true
    public var stayAwake = false
    public var powerOffOnClose = false
    public var showTouches = false
    /// Escape hatch for options not modelled above.
    public var extra: [String: String] = [:]

    public init(scid: UInt32 = UInt32.random(in: 0...0x7fff_ffff)) {
        self.scid = scid & 0x7fff_ffff
    }

    public var socketName: String { String(format: "scrcpy_%08x", scid) }

    public func arguments() -> [String] {
        var args = [
            String(format: "scid=%08x", scid),
            "log_level=\(logLevel)",
            // The server listens and we connect, straight to its abstract socket.
            "tunnel_forward=true",
        ]
        if !video { args.append("video=false") }
        if !audio { args.append("audio=false") }
        if !control { args.append("control=false") }
        if videoCodec != .h264 { args.append("video_codec=\(videoCodec.optionValue)") }
        if audio, audioCodec != .opus { args.append("audio_codec=\(audioCodec.optionValue)") }
        if let videoBitRate { args.append("video_bit_rate=\(videoBitRate)") }
        if let maxSize { args.append("max_size=\(maxSize)") }
        if let maxFps { args.append("max_fps=\(maxFps)") }
        if !powerOn { args.append("power_on=false") }
        if stayAwake { args.append("stay_awake=true") }
        if powerOffOnClose { args.append("power_off_on_close=true") }
        if showTouches { args.append("show_touches=true") }
        args += extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return args
    }

    /// The full command line for `adb shell`.
    public func shellCommand() -> String {
        (["CLASSPATH=\(ScrcpyProtocol.remoteServerPath)", "app_process", "/",
          "com.genymobile.scrcpy.Server", ScrcpyProtocol.serverVersion] + arguments())
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-=./:,@%+")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
