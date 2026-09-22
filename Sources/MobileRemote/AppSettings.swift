import Foundation
import ScrcpyKit

/// Session options: saved preferences first, then command-line overrides
/// such as `MobileRemote --open SERIAL --codec h264 --max-size 1280 --stats`.
struct AppSettings {
    /// H.265 at full resolution kept 58 fps on the mid-range test phone where
    /// H.264 saturated at 50; phones without an HEVC encoder fall back to H.264.
    var codec: StreamCodec = .h265
    var maxSize = 1600
    var bitRate: Int?
    var maxFps = 60
    /// Off by default: it costs the phone ~0.6 core and takes its speaker.
    var audio = false
    /// Off only for comparing against the unrefreshed stream.
    var refreshesWhenSettled = true
    var printStats = false
    /// Mirror this device (adb serial or iOS capture UID) as soon as it is
    /// ready, whatever the auto-open setting.
    var openSerial: String?
    /// Development aid, see `UIPreview`.
    var previewDirectory: String?
    /// Development aid: record this many seconds after the first frame, then stop.
    var autoRecordSeconds: Int?
    /// Development aid: open the settings window at launch.
    var showSettings = false

    // UserDefaults keys, shared with the settings window.
    static let codecKey = "videoCodec", maxSizeKey = "maxSize", bitRateKey = "videoBitRate", maxFpsKey = "maxFps"
    static let audioKey = "audioEnabled"

    static func fromCommandLine(_ arguments: [String] = CommandLine.arguments) -> AppSettings {
        var settings = AppSettings()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: codecKey) == "h264" { settings.codec = .h264 }
        if defaults.object(forKey: maxSizeKey) != nil { settings.maxSize = defaults.integer(forKey: maxSizeKey) }
        if defaults.integer(forKey: bitRateKey) > 0 { settings.bitRate = defaults.integer(forKey: bitRateKey) }
        if defaults.integer(forKey: maxFpsKey) > 0 { settings.maxFps = defaults.integer(forKey: maxFpsKey) }
        settings.audio = defaults.bool(forKey: audioKey)
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--codec":
                if iterator.next() == "h264" { settings.codec = .h264 }
            case "--max-size":
                if let value = iterator.next().flatMap(Int.init) { settings.maxSize = value }
            case "--bit-rate":
                settings.bitRate = iterator.next().flatMap(Int.init)
            case "--no-settle-refresh":
                settings.refreshesWhenSettled = false
            case "--audio":
                settings.audio = true
            case "--stats":
                settings.printStats = true
            case "--open":
                settings.openSerial = iterator.next()
            case "--render-ui":
                settings.previewDirectory = iterator.next()
            case "--auto-record":
                settings.autoRecordSeconds = iterator.next().flatMap(Int.init)
            case "--show-settings":
                settings.showSettings = true
            default:
                break
            }
        }
        return settings
    }

    func serverOptions() -> ScrcpyServerOptions {
        var options = ScrcpyServerOptions()
        options.videoCodec = codec
        options.maxSize = maxSize > 0 ? maxSize : nil
        options.videoBitRate = bitRate
        options.maxFps = maxFps
        options.audio = audio
        return options
    }
}
