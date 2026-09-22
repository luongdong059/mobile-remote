import Foundation
import ScrcpyKit

/// Launch options, e.g. `MobileRemote --open SERIAL --codec h264 --max-size 1280 --stats`.
struct AppSettings {
    /// H.265 at full resolution kept 58 fps on the mid-range test phone where
    /// H.264 saturated at 50; phones without an HEVC encoder fall back to H.264.
    var codec: StreamCodec = .h265
    var maxSize = 1600
    var bitRate: Int?
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

    static func fromCommandLine(_ arguments: [String] = CommandLine.arguments) -> AppSettings {
        var settings = AppSettings()
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
            case "--stats":
                settings.printStats = true
            case "--open":
                settings.openSerial = iterator.next()
            case "--render-ui":
                settings.previewDirectory = iterator.next()
            case "--auto-record":
                settings.autoRecordSeconds = iterator.next().flatMap(Int.init)
            default:
                break
            }
        }
        return settings
    }

    func serverOptions() -> ScrcpyServerOptions {
        var options = ScrcpyServerOptions()
        options.videoCodec = codec
        options.maxSize = maxSize
        options.videoBitRate = bitRate
        return options
    }
}
