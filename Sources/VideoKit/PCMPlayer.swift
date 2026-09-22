import AVFoundation
import Foundation

/// Plays a live stream of interleaved 16-bit PCM with as little buffering as
/// the engine allows. Late audio is dropped rather than queued, so the sound
/// stays in step with the picture after a hiccup.
public final class PCMPlayer: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    private var started = false
    /// More than this waiting to play means we are behind; new audio replaces it.
    private let maxQueuedSeconds = 0.25

    public private(set) var droppedBuffers = 0

    public init(sampleRate: Double = 48_000, channels: Int = 2) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw VideoKitError.coreMedia(operation: "audio format", status: -1)
        }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    /// `data` holds interleaved Int16 samples, little-endian.
    public func enqueue(_ data: Data) {
        let frameCount = data.count / (2 * channels)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for channel in 0..<channels {
                let out = buffer.floatChannelData![channel]
                for frame in 0..<frameCount {
                    out[frame] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32768
                }
            }
        }

        lock.lock()
        if Double(queuedFrames) / sampleRate > maxQueuedSeconds {
            // Behind: throw away what is waiting and start fresh from here.
            lock.unlock()
            node.stop()
            lock.lock()
            queuedFrames = 0
            droppedBuffers += 1
        }
        if !started {
            do {
                try engine.start()
                started = true
            } catch {
                lock.unlock()
                return
            }
        }
        let length = buffer.frameLength
        queuedFrames += length
        lock.unlock()

        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            lock.withLock { queuedFrames = queuedFrames >= length ? queuedFrames - length : 0 }
        }
        if !node.isPlaying { node.play() }
    }

    public func stop() {
        node.stop()
        engine.stop()
    }
}
