import Foundation

public enum VideoCodecKind: Sendable {
    case h264
    case hevc
}

/// Android's MediaCodec emits Annex B (NAL units separated by 00 00 01 start
/// codes); VideoToolbox wants AVCC (each NAL prefixed by its u32 length) with
/// the parameter sets carried out of band in the format description.
public enum AnnexB {
    /// NAL units without their start codes.
    public static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var unitStart: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start = unitStart {
                    // A zero before the start code belongs to a 4-byte start code.
                    let end = index > start && bytes[index - 1] == 0 ? index - 1 : index
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                unitStart = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }

    public static func isParameterSet(_ unit: Data, codec: VideoCodecKind) -> Bool {
        guard let first = unit.first else { return false }
        switch codec {
        case .h264:
            let type = first & 0x1f
            return type == 7 || type == 8 // SPS, PPS
        case .hevc:
            let type = (first >> 1) & 0x3f
            return (32...34).contains(type) // VPS, SPS, PPS
        }
    }

    /// Length-prefixed frame data, with in-band parameter sets dropped.
    public static func avcc(from data: Data, codec: VideoCodecKind) -> Data {
        var output = Data(capacity: data.count + 16)
        for unit in nalUnits(in: data) where !isParameterSet(unit, codec: codec) {
            Swift.withUnsafeBytes(of: UInt32(unit.count).bigEndian) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }
}
