import AVFoundation
import CoreMedia
import Foundation

/// Writes a mirror session to an MP4 file. Two kinds of input:
/// - compressed frames straight from the phone (Android): copied into the
///   file as they are, no re-encoding, so recording costs nearly nothing;
/// - raw pictures (iPhone capture): encoded in hardware on the way in.
///
/// Thread-safe; frames are dropped rather than queued when the writer is
/// busy, so a slow disk never stalls the live picture.
public final class ScreenRecorder: @unchecked Sendable {
    public enum Source {
        /// The format description shared by the frames that will be appended.
        case compressed(CMVideoFormatDescription)
        case pixels(width: Int, height: Int)
    }

    public struct Summary: Sendable {
        public let url: URL
        public let duration: TimeInterval
        public let frames: Int
        public let droppedFrames: Int
    }

    public enum RecorderError: Error, CustomStringConvertible {
        case writer(String)
        case notStarted

        public var description: String {
            switch self {
            case .writer(let detail): return "Không ghi được file: \(detail)"
            case .notStarted: return "Chưa có khung hình nào được ghi"
            }
        }
    }

    public let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let lock = NSLock()
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var frames = 0
    private var dropped = 0
    private var finished = false

    public init(url: URL, source: Source) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        switch source {
        case .compressed(let format):
            // nil settings = pass the samples through untouched.
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            adaptor = nil
        case .pixels(let width, let height):
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // ~12 Mbps for a phone screen: text stays sharp, files stay small.
                    AVVideoAverageBitRateKey: max(4_000_000, width * height * 4),
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                ],
            ]
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer("định dạng không được hỗ trợ") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting")
        }
    }

    /// Seconds of video written so far.
    public var elapsed: TimeInterval {
        lock.withLock {
            guard let firstTime, let lastTime else { return 0 }
            return CMTimeGetSeconds(lastTime - firstTime)
        }
    }

    /// Compressed input. The first appended frame must be a key frame.
    public func append(_ sample: CMSampleBuffer, isKeyFrame: Bool) {
        if !isKeyFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        write(at: time, isKeyFrame: isKeyFrame) { input.append(sample) }
    }

    /// Raw input.
    public func append(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let adaptor else { return }
        write(at: time, isKeyFrame: true) { adaptor.append(pixelBuffer, withPresentationTime: time) }
    }

    private func write(at time: CMTime, isKeyFrame: Bool, _ body: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        if firstTime == nil {
            // A file that starts on a P-frame would not decode.
            guard isKeyFrame else { dropped += 1; return }
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        if let lastTime, time <= lastTime { dropped += 1; return }
        guard input.isReadyForMoreMediaData, body() else { dropped += 1; return }
        lastTime = time
        frames += 1
    }

    /// Closes the file. Blocks briefly while the last samples are flushed.
    public func finish() throws -> Summary {
        lock.lock()
        finished = true
        let started = firstTime != nil
        lock.unlock()
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.notStarted
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "finishWriting")
        }
        return Summary(url: url, duration: elapsed, frames: frames, droppedFrames: dropped)
    }

    /// Where recordings go, and a name that sorts by time.
    public static func defaultURL(deviceName: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = deviceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return recordingsDirectory.appendingPathComponent("\(safe) \(formatter.string(from: Date())).mp4")
    }

    public static var recordingsDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Mobile Remote")
    }
}
